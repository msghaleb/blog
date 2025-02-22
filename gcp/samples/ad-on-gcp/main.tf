provider "google" {
  version = "~> 3.1"
  project = var.project
}

locals {
  regions = var.regions
  zones = var.zones
  name-sample = "ad-on-gce"
  name-domain = var.domain-name
  password = var.password
  network-prefixes = ["10.0.0", "10.1.0"]
  network-mask = 16
  network-ranges = [
    for prefix in local.network-prefixes:
    "${prefix}.0/${local.network-mask}"
  ]
  ip-dcs = [
    for prefix in local.network-prefixes:
    "${prefix}.2"
  ]
}

module "cloud-nat" {
  count = length(local.regions)
  source = "../../modules/cloud-nat"
  region = local.regions[count.index]
  network = google_compute_network.network.name
  depends_on = [google_compute_network.network]
}

module "activedirectory" {
  # source = "github.com/peterschen/blog//gcp/modules/activedirectory"
  source = "../../modules/activedirectory"
  regions = local.regions
  zones = local.zones
  network = google_compute_network.network.name
  subnetworks = [
    for subnet in google_compute_subnetwork.subnetworks:
    subnet.name
  ]
  name-domain = local.name-domain
  password = local.password
  depends_on = [module.cloud-nat]
}

module "bastion" {
  # source = "github.com/peterschen/blog//gcp/modules/bastion-windows"
  source = "../../modules/bastion-windows"
  region = local.regions[0]
  zone = local.zones[0]
  network = google_compute_network.network.name
  subnetwork = google_compute_subnetwork.subnetworks[0].name
  machine-name = "bastion"
  password = local.password
  domain-name = local.name-domain
  enable-domain = true
  depends_on = [module.cloud-nat]
}

module "firewall-iap" {
  # source = "github.com/peterschen/blog//gcp/modules/firewall-iap"
  source = "../../modules/firewall-iap"
  network = google_compute_network.network.name
  enable-ssh = false
}

resource "google_compute_network" "network" {
  name = local.name-sample
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnetworks" {
  count = length(local.regions)
  region = local.regions[count.index]
  name = local.regions[count.index]
  ip_cidr_range = local.network-ranges[count.index]
  network = google_compute_network.network.self_link
  private_ip_google_access = true
}

resource "google_compute_firewall" "allow-all-internal" {
  name    = "allow-all-internal"
  network = google_compute_network.network.name
  priority = 1000

  allow {
    protocol = "all"
  }

  direction = "INGRESS"

  source_ranges = [
    for range in local.network-ranges:
    range
  ]
}
