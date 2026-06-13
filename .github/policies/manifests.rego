package main

# Deny containers using the 'latest' image tag
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("container '%s' uses ':latest' image tag — pin to a specific version", [container.name])
}

# Deny containers without resource limits
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits
  msg := sprintf("container '%s' has no resource limits defined", [container.name])
}

# Deny containers without resource requests
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.requests
  msg := sprintf("container '%s' has no resource requests defined", [container.name])
}

# Warn if no readiness probe
warn[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.readinessProbe
  msg := sprintf("container '%s' has no readinessProbe", [container.name])
}
