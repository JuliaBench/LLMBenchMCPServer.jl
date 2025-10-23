# Sandbox-specific implementation
# This file contains all BB2/Sandbox-related functionality
# All necessary modules are imported in SandboxExt.jl

using TOML
using Sockets
using UUIDs

# BinaryBuilderToolchains is imported in parent module (SandboxExt)
# Access it through the parent scope

function prepare_sandbox_project(project_dir::String, temp_project_dir::String, mounts::Dict, verbose::Bool=false)
    # Create temp directory if needed
    mkpath(temp_project_dir)

    # Copy Project.toml
    project_file = joinpath(project_dir, "Project.toml")
    if isfile(project_file)
        cp(project_file, joinpath(temp_project_dir, "Project.toml"), force=true)
    end

    # Process Manifest.toml
    manifest_file = joinpath(project_dir, "Manifest.toml")
    dev_packages = Dict{String, String}()

    if isfile(manifest_file)
        # Read the manifest
        manifest = TOML.parsefile(manifest_file)

        # Get the deps section where packages are stored
        deps = get(manifest, "deps", Dict())

        # Find dev'd packages (those with path entries)
        for (pkg_name, pkg_info) in deps
            # Handle both old and new manifest formats
            pkg_data = if isa(pkg_info, Vector) && length(pkg_info) > 0
                pkg_info[1]
            else
                pkg_info
            end

            if isa(pkg_data, Dict) && haskey(pkg_data, "path")
                original_path = pkg_data["path"]

                # Always resolve paths relative to the manifest directory
                # joinpath handles absolute paths correctly (returns the absolute path unchanged)
                resolved_path = normpath(joinpath(dirname(manifest_file), original_path))

                if !isdir(resolved_path)
                    if verbose
                        println("  Warning: Dev package $pkg_name path not found: $resolved_path")
                    end
                    # Skip this package
                    continue
                end

                # Create a unique mount point for this package
                sandbox_mount_point = "/opt/dev_packages/$(pkg_name)"

                # Add mount for this package
                mounts[sandbox_mount_point] = Sandbox.MountInfo(resolved_path, Sandbox.MountType.ReadOnly)

                # Update the path in manifest
                pkg_data["path"] = sandbox_mount_point
                dev_packages[pkg_name] = sandbox_mount_point

                if verbose
                    println("  Mounting dev package $pkg_name: $resolved_path -> $sandbox_mount_point")
                end
            end
        end

        # Write modified manifest
        open(joinpath(temp_project_dir, "Manifest.toml"), "w") do io
            TOML.print(io, manifest)
        end
    end

    return dev_packages
end

"""
    PythonToolchain

A toolchain that provides Python 3 for scripting in the build environment.
"""
struct PythonToolchain <: BinaryBuilderToolchains.AbstractToolchain
    platform::Base.BinaryPlatforms.AbstractPlatform

    function PythonToolchain(platform)
        new(platform)
    end
end

# Implement the required interface methods
function BinaryBuilderToolchains.toolchain_sources(toolchain::PythonToolchain)
    # Convert platform if it's a CrossPlatform
    platform = toolchain.platform
    if isa(platform, BinaryBuilderToolchains.CrossPlatform)
        platform = platform.host
    end

    # Create Python JLL source
    python_source = BinaryBuilderSources.JLLSource("Python_jll", platform)
    return [python_source]
end

function BinaryBuilderToolchains.toolchain_env(toolchain::PythonToolchain, deployed_prefix::String)
    env = Dict{String,String}()

    # Add Python's bin directory to PATH
    BinaryBuilderToolchains.insert_PATH!(env, :PRE, [
        joinpath(deployed_prefix, "bin"),
    ])

    # Set Python-specific environment variables
    env["PYTHON"] = joinpath(deployed_prefix, "bin", "python3")
    env["PYTHON3"] = joinpath(deployed_prefix, "bin", "python3")

    # Also set PYTHONHOME to help Python find its libraries
    env["PYTHONHOME"] = deployed_prefix

    return env
end

function BinaryBuilderToolchains.platform(toolchain::PythonToolchain)
    return toolchain.platform
end

# PlatformlessWrapper support for PythonToolchain
function PythonToolchain(; kwargs...)
    return BinaryBuilder2.PlatformlessWrapper{PythonToolchain}(; kwargs=Dict(kwargs...))
end

function BinaryBuilder2.apply_platform(pw::BinaryBuilder2.PlatformlessWrapper{PythonToolchain}, platform::Base.BinaryPlatforms.AbstractPlatform)
    return PythonToolchain(platform)
end

function BinaryBuilder2.apply_platform(pt::PythonToolchain, p::Base.BinaryPlatforms.AbstractPlatform)
    if !BinaryBuilderToolchains.platforms_match(pt.platform, p)
        throw(ArgumentError("Attempted to `apply_platform` a PythonToolchain with platform $(triplet(pt.platform)) but for $(triplet(p))"))
    end
    return pt
end

function BinaryBuilder2.PlatformlessWrapper(pt::PythonToolchain)
    return PythonToolchain()
end

# Install these into the tools directory as well
BinaryBuilder2.toolchain_prefix(bts::BinaryBuilder2.BuildTargetSpec, ::PythonToolchain) = "/opt/$(bts.name)-tools"

"""
    bb2_target_spec()

Create a basic build environment using BB2 approach for the host platform.
Includes Python for scripting support.
"""
function bb2_target_spec()
    # Create a basic build environment using BB2 approach
    host_platform = BinaryBuilderToolchains.BBHostPlatform()
    platform = BinaryBuilderToolchains.CrossPlatform(host_platform, host_platform)

    # Create BuildTargetSpec with CToolchain, HostToolsToolchain, and PythonToolchain
    return BinaryBuilder2.BuildTargetSpec(
        "bb2",
        platform,
        [
            BinaryBuilderToolchains.CToolchain(;lock_microarchitecture=false),
            HostToolsToolchain(),
            PythonToolchain()
        ],
        [],  # No additional dependencies
        Set([:host, :default])
    )
end

"""
    create_sandbox_config(workspace::String, verbose::Bool, forward_ssh::Bool=false)

Create common sandbox configuration including mounts and environment.
Returns (mounts, env, sandbox_depot_path)
"""
function LLMBenchMCPServer.create_sandbox_config(workspace::String, verbose::Bool, forward_ssh::Bool=false)
    # Get host platform for debian_rootfs
    host_platform = Base.BinaryPlatforms.HostPlatform()

    # Create minimal mounts for the sandbox
    mounts = Dict{String, Sandbox.MountInfo}(
        "/" => Sandbox.MountInfo(Sandbox.debian_rootfs(; platform=host_platform), Sandbox.MountType.Overlayed),
        "/workspace" => Sandbox.MountInfo(workspace, Sandbox.MountType.ReadWrite),
    )

    # Set up BinaryBuilder2 toolchain
    toolchain_mounts, toolchain_env = setup_bb2_toolchain(verbose)
    merge!(mounts, toolchain_mounts)

    # Mount Julia installation
    julia_bin = Base.julia_cmd().exec[1]
    julia_dir = dirname(dirname(julia_bin))
    if isdir(julia_dir)
        mounts["/opt/julia"] = Sandbox.MountInfo(julia_dir, Sandbox.MountType.ReadOnly)
    end

    # Get or create sandbox depot
    sandbox_depot = @get_scratch!("sandbox_julia_depot")
    mounts["/root/.julia"] = Sandbox.MountInfo(sandbox_depot, Sandbox.MountType.ReadWrite)

    # Create a generic git config for the sandbox
    gitconfig_dir = @get_scratch!("sandbox_gitconfig")
    gitconfig_path = joinpath(gitconfig_dir, ".gitconfig")
    if !isfile(gitconfig_path)
        open(gitconfig_path, "w") do io
            println(io, """
            [user]
                name = LLMBench User
                email = user@llmbench.local
            [init]
                defaultBranch = main
            [core]
                editor = vim
            [push]
                default = simple
            """)
        end
    end
    mounts["/root/.gitconfig"] = Sandbox.MountInfo(gitconfig_path, Sandbox.MountType.ReadOnly)

    # Set up environment
    env = copy(toolchain_env)
    # Include standard system paths in PATH
    # The Python path will be included via toolchain_env if Python is in the toolchain
    env["PATH"] = "/opt/julia/bin:/opt/bb2-x86_64-linux-gnu/wrappers:/opt/bb2-tools/wrappers:/opt/bb2-tools/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["HOME"] = "/root"
    env["USER"] = "root"
    env["JULIA_DEPOT_PATH"] = "/root/.julia"

    # Set SSL certificates
    if haskey(env, "SSL_CERT_FILE")
        env["JULIA_SSL_CA_ROOTS_PATH"] = env["SSL_CERT_FILE"]
        if verbose
            println("SSL certificates: $(env["SSL_CERT_FILE"])")
        end
    end

    # Forward ANTHROPIC_API_KEY if set
    if haskey(ENV, "ANTHROPIC_API_KEY")
        env["ANTHROPIC_API_KEY"] = ENV["ANTHROPIC_API_KEY"]
        if verbose
            println("Forwarding ANTHROPIC_API_KEY to sandbox")
        end
    end

    # Handle SSH agent forwarding
    if forward_ssh
        ssh_auth_sock = get(ENV, "SSH_AUTH_SOCK", nothing)
        if ssh_auth_sock !== nothing && ispath(ssh_auth_sock)
            sandbox_ssh_path = "/tmp/ssh-auth.sock"
            mounts[sandbox_ssh_path] = Sandbox.MountInfo(ssh_auth_sock, Sandbox.MountType.ReadWrite)
            env["SSH_AUTH_SOCK"] = sandbox_ssh_path
            if verbose
                println("Forwarding SSH agent from $ssh_auth_sock to $sandbox_ssh_path")
            end
        elseif verbose
            println("Warning: --forward-ssh specified but SSH_AUTH_SOCK not found or not valid")
        end
    end

    return mounts, env, sandbox_depot
end

# Generate a unique UUID each time the module loads to invalidate cache on code changes
const BB2_TOOLCHAIN_UUID = string(@isdefined(uuid7) ? uuid7() : uuid4())

"""
    setup_bb2_toolchain(verbose::Bool=false) -> (mounts::Dict, env::Dict)

Set up BinaryBuilder2 toolchain and return mounts and environment variables.
Uses OnceInitScratch to ensure the toolchain is only downloaded and set up once.
"""
# Function to set up the BB2 toolchain in a scratch directory
function setup_bb2_toolchain_impl(toolchain_dir::String)
    println("Setting up BinaryBuilder2 toolchain in $toolchain_dir...")

    target_spec = bb2_target_spec()

    # Apply toolchains to get sources and environment
    env = Dict{String,String}()
    source_trees = Dict{String,Vector{BinaryBuilderSources.AbstractSource}}()
    env, source_trees = BinaryBuilder2.apply_toolchains(target_spec, env, source_trees)

    # No longer need to validate - BB2 fix prevents empty keys

    # Deploy toolchain sources to the scratch directory
    for (idx, (prefix, sources)) in enumerate(source_trees)
        if startswith(prefix, "/opt/")
            deploy_path = joinpath(toolchain_dir, string(idx, "-", lstrip(prefix, '/')))
            mkpath(deploy_path)

            println("  Deploying $prefix to $deploy_path")

            BinaryBuilderSources.prepare(sources)
            BinaryBuilderSources.deploy(sources, deploy_path)
        end
    end

    println("✓ BinaryBuilder2 toolchain installed")
    return toolchain_dir
end

# Create the OnceInitScratch for the toolchain
const bb2_toolchain_scratchspace = Scratch.@OnceInitScratch(setup_bb2_toolchain_impl, BB2_TOOLCHAIN_UUID)

function setup_bb2_toolchain(verbose::Bool=false)
    # Get the toolchain directory (will be initialized on first access)
    toolchain_dir = bb2_toolchain_scratchspace()

    if verbose
        println("Using BinaryBuilder2 toolchain from $toolchain_dir")
    end

    # Build mounts for the toolchain by re-creating the source trees
    # This ensures we get the exact same prefixes as when we deployed
    target_spec = bb2_target_spec()
    env = Dict{String,String}()
    source_trees = Dict{String,Vector{BinaryBuilderSources.AbstractSource}}()
    env, source_trees = BinaryBuilder2.apply_toolchains(target_spec, env, source_trees)

    # No longer need to validate - BB2 fix prevents empty keys

    mounts = Dict{String, Sandbox.MountInfo}()
    for (idx, (prefix, sources)) in enumerate(source_trees)
        if startswith(prefix, "/opt/")
            # Use the same naming convention as deployment
            host_path = joinpath(toolchain_dir, string(idx, "-", lstrip(prefix, '/')))
            if isdir(host_path)
                mounts[prefix] = Sandbox.MountInfo(host_path, Sandbox.MountType.Overlayed)
                if verbose
                    println("  Mount: $prefix -> $host_path")
                end
            elseif verbose
                println("  Warning: Expected toolchain directory not found: $host_path")
            end
        end
    end

    return mounts, env
end

"""
    launch_sandbox_bash(args::Vector{String}, workspace::String, verbose::Bool, forward_ssh::Bool=false)

Launch an interactive bash shell inside the sandbox environment with all the same
mounts and environment as the regular sandbox mode.
"""
function LLMBenchMCPServer.launch_sandbox_bash(args::Vector{String}, workspace::String, verbose::Bool, forward_ssh::Bool=false)::Cint
    println("Setting up sandbox environment with bash shell...")

    # Use common sandbox setup
    mounts, env, sandbox_depot = LLMBenchMCPServer.create_sandbox_config(workspace, verbose, forward_ssh)

    # Prepare temporary project directory with proper handling of dev'd packages
    # This allows the user to launch the server themselves for debugging
    project_dir = dirname(Base.active_project())
    temp_project_dir = mktempdir()

    if verbose
        println("Preparing sandbox project in $temp_project_dir")
        println("Using project from: $project_dir")
    end

    # Prepare the project and get dev package mappings
    dev_packages = prepare_sandbox_project(project_dir, temp_project_dir, mounts, verbose)

    # Mount the temp project directory as read-only
    mounts["/opt/llmbench"] = Sandbox.MountInfo(temp_project_dir, Sandbox.MountType.ReadOnly)

    # Add project-specific environment variable
    env["JULIA_PROJECT"] = "/opt/llmbench"

    # Create SandboxConfig
    config = Sandbox.SandboxConfig(
        mounts,
        env;
        hostname="llmbench-sandbox",
        persist=false,
        stdin=Base.stdin,
        stdout=Base.stdout,
        stderr=Base.stderr,
        pwd="/workspace"
    )

    println("""

    Entering sandbox bash shell...
    - Working directory: /workspace
    - Julia available at: /opt/julia/bin/julia
    - Julia project at: /opt/llmbench
    - Build tools in: /opt/bb2-x86_64-linux-gnu and /opt/bb2-tools
    - To launch the server: /opt/julia/bin/julia --project=/opt/llmbench -m LLMBenchMCPServer <args> --direct
    - Type 'exit' to leave the sandbox

    """)

    # Run bash interactively in the sandbox
    exit_code = Cint(0)
    try
        Sandbox.with_executor() do exe
            run(exe, config, `/bin/bash`)
        end
    catch e
        println(stderr, "Error running bash in sandbox: $e")
        exit_code = Cint(1)
    end

    println("\nExited sandbox bash shell")
    return exit_code
end

"""
    launch_in_sandbox(args::Vector{String}, use_socket::Bool, socket_path::String, workspace::String, verbose::Bool, forward_ssh::Bool=false)

Re-launch the LLMBenchMCPServer inside a Sandbox.jl sandbox.
If use_socket is true, creates a socket and passes it as fd3 to the sandboxed process.
If forward_ssh is true, forwards SSH agent authentication to the sandbox.
"""
function LLMBenchMCPServer.launch_in_sandbox(args::Vector{String}, use_socket::Bool, socket_path::String, workspace::String, verbose::Bool, forward_ssh::Bool=false)::Cint
    # Use common sandbox setup
    mounts, env, sandbox_depot = LLMBenchMCPServer.create_sandbox_config(workspace, verbose, forward_ssh)

    # Prepare temporary project directory with proper handling of dev'd packages
    # Use the currently active project, not the LLMBenchMCPServer source directory
    project_dir = dirname(Base.active_project())
    temp_project_dir = mktempdir()

    if verbose
        println("Preparing sandbox project in $temp_project_dir")
        println("Using project from: $project_dir")
    end

    # Prepare the project and get dev package mappings
    dev_packages = prepare_sandbox_project(project_dir, temp_project_dir, mounts, verbose)

    # Mount the temp project directory as read-only
    mounts["/opt/llmbench"] = Sandbox.MountInfo(temp_project_dir, Sandbox.MountType.ReadOnly)

    # Add project-specific environment variable
    env["JULIA_PROJECT"] = "/opt/llmbench"

    # Build the command to run inside the sandbox
    # Add --direct flag to prevent infinite recursion
    new_args = copy(args)
    push!(new_args, "--direct")
    # Remove --forward-ssh since we've already handled it
    filter!(x -> x != "--forward-ssh", new_args)

    # Update workspace path to /workspace in sandbox
    for i in 1:length(new_args)
        if new_args[i] == "--workspace" && i < length(new_args)
            new_args[i+1] = "/workspace"
            break
        end
    end

    # Prepare for socket passing if needed
    socket_server = nothing

    if use_socket
        # When sandboxing with socket mode, ALWAYS use fd3 to pass the socket
        # Use the provided socket_path or create a temporary one
        actual_socket_path = if !isempty(socket_path)
            socket_path
        else
            tempname() * ".sock"
        end

        socket_server = Sockets.PipeServer()
        bind(socket_server, actual_socket_path)

        if verbose
            println("Bound server socket at $actual_socket_path, will pass as fd3 to sandbox")
        end

        # Tell the child to use fd3 to receive the socket
        # Remove any existing socket args
        filter!(x -> !(x in ["--socket", "--bind-socket", "--fd3"] || startswith(x, "/tmp/")), new_args)
        push!(new_args, "--fd3")
    end

    # Build the Julia command
    julia_cmd = `/opt/julia/bin/julia --project=/opt/llmbench`
    base_cmd = `$julia_cmd -m LLMBenchMCPServer $new_args`

    # If we have a socket server, wrap the command with CmdRedirect to pass it as fd3
    if socket_server !== nothing
        # Create the CmdRedirect to pass socket as fd3
        cmd = Base.CmdRedirect(base_cmd, socket_server, 3)
        if verbose
            println("Wrapping command with CmdRedirect for fd3 socket passing")
        end
    else
        cmd = base_cmd
    end

    # Create the sandbox configuration
    config = Sandbox.SandboxConfig(
        mounts,
        env;
        stdin=Base.stdin,
        stdout=Base.stdout,
        stderr=Base.stderr,
        pwd="/workspace"
    )

    # Run in the sandbox
    exit_code = Cint(0)
    try
        Sandbox.with_executor() do exe
            # Try to instantiate packages, but continue even if it fails
            # (packages might already be available in the depot)
            try
                run(exe, config, `$julia_cmd -e 'using Pkg; Pkg.instantiate();'`)
            catch e
                if verbose
                    println("Warning: Pkg.instantiate() failed: $e")
                    println("Continuing anyway - packages may already be available")
                end
            end

            # Run the main command
            run(exe, config, cmd)
        end
    catch e
        println(stderr, "Error running in sandbox: $e")
        exit_code = Cint(1)
    finally
        # Clean up
        if socket_server !== nothing
            close(socket_server)
            # Clean up the socket file if it was created
            # Note: Use ispath() not isfile() for Unix domain sockets
            if use_socket && @isdefined(actual_socket_path) && ispath(actual_socket_path)
                try
                    rm(actual_socket_path, force=true)
                    if verbose
                        println("Cleaned up socket file: $actual_socket_path")
                    end
                catch
                    # Ignore cleanup errors
                end
            end
        end

        # Clean up temp project directory
        try
            rm(temp_project_dir, recursive=true, force=true)
            if verbose
                println("Cleaned up temp project directory")
            end
        catch
            # Ignore cleanup errors
        end
    end

    return exit_code
end
