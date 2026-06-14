package main

# Deny containers without resource limits
deny contains msg if {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits
  msg := sprintf("container '%s' has no resource limits defined", [container.name])
}

# Deny containers without resource requests
deny contains msg if {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.requests
  msg := sprintf("container '%s' has no resource requests defined", [container.name])
}

# Warn if no readiness probe
warn contains msg if {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.readinessProbe
  msg := sprintf("container '%s' has no readinessProbe", [container.name])
}
