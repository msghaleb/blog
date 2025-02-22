locals {
  region = var.region
  zone = var.zone
  name-domain = var.domain-name
  password = var.password
  network = var.network
  subnetwork = var.subnetwork
  machine-type = var.machine-type
  enable-cluster = var.enable-cluster
  enable-hdd = var.enable-hdd
  count-nodes = var.node-count
  count-disks = 4
  size-disks = 100
}

data "google_compute_network" "network" {
  name = local.network
}

data "google_compute_subnetwork" "subnetwork" {
  region = local.region
  name = local.subnetwork
}

module "apis" {
  # source = "github.com/peterschen/blog//gcp/modules/apis"
  source = "../apis"
  apis = ["cloudresourcemanager.googleapis.com", "compute.googleapis.com"]
}

module "gce-default-scopes" {
  # source = "github.com/peterschen/blog//gcp/modules/gce-default-scopes"
  source = "../gce-default-scopes"
}

module "sysprep" {
  # source = "github.com/peterschen/blog//gcp/modules/sysprep"
  source = "../sysprep"
}

module "firewall-sofs" {
  # source = "github.com/peterschen/blog//gcp/modules/firewall-sofs"
  source = "../firewall-sofs"
  name = "allow-sofs"
  network = data.google_compute_network.network
  cidr-ranges = [data.google_compute_subnetwork.subnetwork.ip_cidr_range]
}

resource "google_compute_address" "sofs" {
  count = local.count-nodes
  region = local.region
  subnetwork = data.google_compute_subnetwork.subnetwork.self_link
  name = "sofs-${count.index}"
  address_type = "INTERNAL"
}

resource "google_compute_address" "sofs-cl" {
  region = local.region
  name = "sofs-cl"
  address_type = "INTERNAL"
  subnetwork = data.google_compute_subnetwork.subnetwork.self_link
}

resource "google_compute_firewall" "allow-healthcheck-sofs-gcp" {
  name = "allow-healthcheck-sofs-gcp"
  network = data.google_compute_network.network.self_link
  priority = 5000

  allow {
    protocol = "tcp"
    ports    = ["59998"]
  }

  direction = "INGRESS"

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags = ["sofs"]
}

resource "google_compute_instance" "sofs" {
  count = local.count-nodes
  zone = local.zone
  name = "sofs-${count.index}"
  machine_type = local.machine-type

  tags = ["sofs", "rdp"]

  boot_disk {
    initialize_params {
      image = "windows-cloud/windows-2019"
      type = "pd-ssd"
    }
  }

  network_interface {
    network = data.google_compute_network.network.self_link
    subnetwork = data.google_compute_subnetwork.subnetwork.self_link
    network_ip = google_compute_address.sofs[count.index].address
  }

  metadata = {
    type = "sofs"
    enable-wsfc = "true"
    sysprep-specialize-script-ps1 = templatefile(module.sysprep.path-specialize, { 
        nameHost = "sofs-${count.index}", 
        password = local.password,
        parametersConfiguration = jsonencode({
          inlineMeta = filebase64(module.sysprep.path-meta),
          inlineConfiguration = filebase64("${path.module}/sofs.ps1"),
          domainName = local.name-domain,
          isFirst = (count.index == 0),
          nodePrefix = "sofs",
          nodeCount = local.count-nodes,
          enableCluster = local.enable-cluster,
          ipCluster = google_compute_address.sofs-cl.address,
          modulesDsc = [
            {
              Name = "xFailOverCluster",
              Version = "1.14.1"
              Uri = "https://github.com/dsccommunity/xFailOverCluster/archive/v1.14.1.zip"
            }
          ]
        })
      })
  }

  service_account {
    scopes = module.gce-default-scopes.scopes
  }

  lifecycle {
    ignore_changes = [attached_disk]
  }

  depends_on = [module.apis]
}

resource "google_compute_disk" "sofs-hdd" {
  count = local.enable-hdd ? local.count-nodes * local.count-disks : 0
  zone = google_compute_instance.sofs[floor(count.index / local.count-disks)].zone
  name = "sofs-hdd-${count.index}"
  type = "pd-standard"
  size = local.size-disks
}

resource "google_compute_attached_disk" "sofs-hdd" {
  count = local.enable-hdd ? local.count-nodes * local.count-disks : 0
  disk = google_compute_disk.sofs-hdd[count.index].self_link
  instance = google_compute_instance.sofs[floor(count.index / local.count-disks)].self_link
}

resource "google_compute_disk" "sofs-ssd" {
  count = local.count-nodes * local.count-disks
  zone = google_compute_instance.sofs[floor(count.index / local.count-disks)].zone
  name = "sofs-ssd-${count.index}"
  type = "pd-ssd"
  size = local.size-disks
}

resource "google_compute_attached_disk" "sofs-ssd" {
  count = local.count-nodes * local.count-disks
  disk = google_compute_disk.sofs-ssd[count.index].self_link
  instance = google_compute_instance.sofs[floor(count.index / local.count-disks)].self_link
}

resource "google_compute_instance_group" "sofs" {
  count = local.count-nodes
  zone = local.zone
  name = "sofs-${count.index}"
  instances = [google_compute_instance.sofs[count.index].self_link]
  network = data.google_compute_network.network.self_link
}

resource "google_compute_health_check" "sofs" {
  name = "sofs"
  timeout_sec = 1
  check_interval_sec = 2

  tcp_health_check {
    port = 59998
    request = google_compute_address.sofs-cl.address
    response = "1"
  }
}

resource "google_compute_region_backend_service" "sofs" {
  region = local.region
  name = "sofs"
  health_checks = [google_compute_health_check.sofs.self_link]

  dynamic "backend" {
    for_each = google_compute_instance_group.sofs
    content {
      group = backend.value.self_link
    }
  }
}

resource "google_compute_forwarding_rule" "sofs" {
  region = local.region
  name = "sofs"
  ip_address = google_compute_address.sofs-cl.address
  load_balancing_scheme = "INTERNAL"
  all_ports = true
  allow_global_access = true
  network = data.google_compute_network.network.self_link
  subnetwork = data.google_compute_subnetwork.subnetwork.self_link
  backend_service = google_compute_region_backend_service.sofs.self_link
}
