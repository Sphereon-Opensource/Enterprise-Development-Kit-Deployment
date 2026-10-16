package system.authz

import rego.v1

# OPA is a private decision service. Its policy/data/query administration APIs
# are unavailable; policy and immutable data are supplied by read-only mounts.
default allow = false

allow if {
    input.method == "POST"
    input.path == ["v1", "data", "sphereon", "authz"]
}

allow if {
    input.method == "GET"
    input.path == ["health"]
}
