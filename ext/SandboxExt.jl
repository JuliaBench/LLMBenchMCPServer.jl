module SandboxExt

using LLMBenchMCPServer
using Sandbox
using BinaryBuilder2
using Scratch

# Access BinaryBuilderToolchains through BinaryBuilder2
import BinaryBuilder2: BinaryBuilderToolchains, BinaryBuilderSources

# Re-export functions that need to be available when extension is loaded
import LLMBenchMCPServer: has_sandbox_support, create_sandbox_config, launch_in_sandbox, launch_sandbox_bash

# Extension indicates Sandbox support is available
LLMBenchMCPServer.has_sandbox_support() = true

# Include sandbox implementation functions
include("sandbox_impl.jl")

end # module SandboxExt
