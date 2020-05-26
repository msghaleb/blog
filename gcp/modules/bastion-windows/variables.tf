variable "project" {
    type = string
}

variable "zone" {
    type = string
}

variable "network" {
}

variable "subnetwork" {
}

variable "machine-type" {
    type = string
    default = "n1-standard-2"
}

variable "password" {
    type = string
}

variable "uri-meta" {
    type = string
}
