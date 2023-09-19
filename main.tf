# see https://github.com/hashicorp/terraform
terraform {
  required_version = "1.5.7"
  required_providers {
    # see https://registry.terraform.io/providers/hashicorp/random
    random = {
      source  = "hashicorp/random"
      version = "3.5.1"
    }
    # see https://registry.terraform.io/providers/hashicorp/template
    template = {
      source  = "hashicorp/template"
      version = "2.2.0"
    }
    # see https://registry.terraform.io/providers/dmacvicar/libvirt
    # see https://github.com/dmacvicar/terraform-provider-libvirt
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.7.1"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

variable "prefix" {
  type    = string
  default = "ceph"
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.7.1/website/docs/r/network.markdown
resource "libvirt_network" "ceph_network" {
  name      = var.prefix
  mode      = "nat"
  domain    = "ceph.test"
  addresses = ["10.17.3.0/24"]
  dhcp {
    enabled = false
  }
  dns {
    enabled    = true
    local_only = false
  }
}

# create a cloud-init cloud-config.
# NB this creates an iso image that will be used by the NoCloud cloud-init datasource.
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.7.1/website/docs/r/cloudinit.html.markdown
# see journactl -u cloud-init
# see /run/cloud-init/*.log
# see https://cloudinit.readthedocs.io/en/latest/topics/examples.html#disk-setup
# see https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html#datasource-nocloud
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.7.1/libvirt/cloudinit_def.go#L133-L162
resource "libvirt_cloudinit_disk" "ceph_cloudinit" {
  count = 3
  name      = "${var.prefix}_cloudinit_${count.index}.iso"
  user_data = <<EOF
#cloud-config
ssh_pwauth: True
chpasswd:
  list: |
     root:linux
  expire: False
fqdn: ceph.test
manage_etc_hosts: true
users:
  - name: vagrant
    passwd: '$6$rounds=4096$.LnRXFeOXL5ik7t8$gGMDoOMZCThNb/1/8vnJQYvbgbeF6FFF6MTIobWppIRcQNL1epegpWOaztCcXiub.zB5J79EaQU6Jqshs.61d/'
    lock_passwd: false
    ssh-authorized-keys:
      - ${jsonencode(trimspace(file("~/.ssh/id_rsa.pub")))}
    sudo:  ALL=(ALL) NOPASSWD:ALL
  - name: rklimenk
    passwd: '$6$rounds=4096$.LnRXFeOXL5ik7t8$gGMDoOMZCThNb/1/8vnJQYvbgbeF6FFF6MTIobWppIRcQNL1epegpWOaztCcXiub.zB5J79EaQU6Jqshs.61d/'
    lock_passwd: false
    ssh-authorized-keys:
      - ${jsonencode(trimspace(file("~/.ssh/id_rsa.pub")))}
    sudo:  ALL=(ALL) NOPASSWD:ALL
#disk_setup:
#  /dev/sdb:
#    table_type: mbr
#    layout:
#      - [100, 83]
#    overwrite: false
#disk_setup:
#  /dev/sdc:
#    table_type: mbr
#    layout:
#      - [100, 83]
#    overwrite: false
#fs_setup:
#  - label: data
#    device: /dev/sdb1
#    filesystem: ext4
#    overwrite: false
#mounts:
#  - [/dev/sdb1, /data, ext4, 'defaults,discard,nofail', '0', '2']
runcmd:
  - sed -i '/vagrant insecure public key/d' /home/vagrant/.ssh/authorized_keys
EOF
}

resource "libvirt_volume" "ubuntu_22" {
  name   = "ubuntu_22"
  source =  "/opt/libvirt-pool/box.img"
}

resource "libvirt_volume" "ceph_root" {
  count            = 3
  name             = "${var.prefix}_root_${count.index}.img"
  base_volume_id   = libvirt_volume.ubuntu_22.id
  format           = "qcow2"
  size             = 15 * 1024 * 1024 * 1024 # 10GiB. the root FS is automatically resized by cloud-init growpart (see https://cloudinit.readthedocs.io/en/latest/topics/examples.html#grow-partitions).
  depends_on       = [ libvirt_volume.ubuntu_22 ]
}

resource "libvirt_volume" "ceph_osd1" {
  count  = 3
  name   = "${var.prefix}_osd1_${count.index}.img"
  format = "qcow2"
  size   = 15 * 1024 * 1024 * 1024 # 15GiB.
}

resource "libvirt_volume" "ceph_osd2" {
  count  = 3
  name   = "${var.prefix}_osd2_${count.index}.img"
  format = "qcow2"
  size   = 15 * 1024 * 1024 * 1024 # 15GiB.
}

resource "libvirt_domain" "ceph_vm" {
  count   = 3
  name    = "${var.prefix}_vm_${count.index}"
  machine = "q35"
  cpu {
    mode = "host-passthrough"
  }
  vcpu       = 2
  memory     = 2048
  qemu_agent = true
  cloudinit  = libvirt_cloudinit_disk.ceph_cloudinit[count.index].id
  xml {
    xslt = file("libvirt-domain.xsl")
  }
  video {
    type = "qxl"
  }
  disk {
    volume_id = libvirt_volume.ceph_root[count.index].id
    scsi      = true
  }
  disk {
    volume_id = libvirt_volume.ceph_osd1[count.index].id
    scsi      = true
  }
  disk {
    volume_id = libvirt_volume.ceph_osd2[count.index].id
    scsi      = true
  }
  network_interface {
    network_id     = libvirt_network.ceph_network.id
    wait_for_lease = true
    addresses      = ["10.17.3.${count.index+2}"]
  }
  provisioner "remote-exec" {
    inline = [
      <<-EOF
      set -x
      id
      uname -a
      cat /etc/os-release
      echo "machine-id is $(cat /etc/machine-id)"
      hostname --fqdn
      cat /etc/hosts
      sudo sfdisk -l
      lsblk -x KNAME -o KNAME,SIZE,TRAN,SUBSYSTEMS,FSTYPE,UUID,LABEL,MODEL,SERIAL
      mount | grep ^/dev
      df -h
      EOF
    ]
    connection {
      type        = "ssh"
      user        = "vagrant"
      host        = self.network_interface[0].addresses[0] # see https://github.com/dmacvicar/terraform-provider-libvirt/issues/660
      private_key = file("~/.ssh/id_rsa")
    }
  }
  lifecycle {
    ignore_changes = [
      disk[0].wwn,
      disk[1].wwn,
    ]
  }
}

output "ip" {
  value = libvirt_domain.ceph_vm[*].network_interface[0].addresses[0]
}
