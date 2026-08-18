// Based on https://github.com/crazy-max/docker-linguist/blob/master/docker-bake.hcl

variable "DEFAULT_TAG" {
  default = "pdfulator:local"
}

// Special target: https://github.com/docker/metadata-action#bake-definition
target "docker-metadata-action" {
  tags = ["${DEFAULT_TAG}"]
}

// Default target if none specified
group "default" {
  targets = ["image-local"]
}

// The Dockerfile moved into the engine that owns it (engines/vivlio-docker),
// so it must be named explicitly -- the default ./Dockerfile no longer exists.
// The context stays the repository root: the image needs the vivlio engine's
// main.js and lockfile plus the shared defaults/ and theme/, which live above
// the engine directory.
//
// Still a single target. Step 9 of the modular plan generalises this into a
// matrix over the container engines, tagging :<engine> per image; until then
// this builds the one that exists.
target "image" {
  inherits = ["docker-metadata-action"]
  context    = "."
  dockerfile = "engines/vivlio-docker/Dockerfile"
}

target "image-local" {
  inherits = ["image"]
  output = ["type=docker"]
}

target "image-all" {
  inherits = ["image"]
  platforms = [
    "linux/amd64",
    "linux/arm64"
  ]
}
