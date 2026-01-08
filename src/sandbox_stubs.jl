# Sandbox functionality stubs
# These functions are defined with 0 methods and will be implemented by the SandboxExt extension

"""
    has_sandbox_support()

Check if Sandbox support is available (i.e., if the SandboxExt extension is loaded).
Will be implemented by the extension to return true when loaded.
"""
function has_sandbox_support end

"""
    create_sandbox_config(workspace::String, verbose::Bool, forward_ssh::Bool=false)

Create sandbox configuration. Will be implemented by the SandboxExt extension.
"""
function create_sandbox_config end

"""
    launch_in_sandbox(args::Vector{String}, use_socket::Bool, socket_path::String, workspace::String, verbose::Bool, forward_ssh::Bool=false, output_dirs::Vector{String}=String[])

Launch the server in a sandbox. Will be implemented by the SandboxExt extension.
If output_dirs is provided, moves those directories to /tmp/output_dirs after the sandbox exits.
"""
function launch_in_sandbox end

"""
    launch_sandbox_bash(args::Vector{String}, workspace::String, verbose::Bool, forward_ssh::Bool=false)

Launch an interactive bash shell in the sandbox. Will be implemented by the SandboxExt extension.
"""
function launch_sandbox_bash end
