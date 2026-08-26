// Based on https://github.com/crazy-max/docker-linguist/blob/master/docker-bake.hcl

variable "DEFAULT_TAG" {
  default = "pdfulator:local"
}

// The engine this invocation builds -- one per bake call, since each engine
// has its own Dockerfile and its own tag set. Read from the environment, which
// is how bake takes a `variable`.
//
// Tags are deliberately not set here: docker-metadata-action computes them and
// hands them over through the generated bake-meta.json, so engine.conf's
// `image=` key stays the one place an image is named.
variable "ENGINE" {
  default = "vivlio-docker"
}

// Special target: https://github.com/docker/metadata-action#bake-definition
target "docker-metadata-action" {
  tags = ["${DEFAULT_TAG}"]
}

// Default target if none specified
group "default" {
  targets = ["image-local"]
}

// The Dockerfile lives in the engine that owns it, so it is named explicitly:
// there is no ./Dockerfile any more. The context stays the repository root --
// an image needs the engine's own sources plus the shared themes/, which live
// above the engine directory.
target "image" {
  inherits   = ["docker-metadata-action"]
  context    = "."
  dockerfile = "engines/${ENGINE}/Dockerfile"
}

target "image-local" {
  inherits = ["image"]
  output   = ["type=docker"]
}

target "image-all" {
  inherits = ["image"]
  platforms = [
    "linux/amd64",
    "linux/arm64"
  ]
}
