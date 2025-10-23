# Development Guidelines for LLMBenchMCPServer.jl

## Important Notes

### Unix Domain Sockets
- **Always use `ispath()` not `isfile()` to check for Unix domain sockets**
- Unix domain sockets are not regular files, so `isfile()` returns false
- This applies to checking SSH_AUTH_SOCK, server sockets, and any socket cleanup

### Environment Variables
- **ANTHROPIC_API_KEY is automatically forwarded to the sandbox**
- If set in the host environment, it will be available in the sandboxed process
- This allows tools inside the sandbox to use the Anthropic API

## Shipping Code

When asked to "ship it" or after making changes:

1. Stage all changes: `git add -A`
2. Create a descriptive commit message
3. Run tests locally and make sure they pass: `julia --project=. -e 'using Pkg; Pkg.test()'`
4. Push to the repository: `git push origin master`
5. **IMPORTANT**: Monitor the GitHub Actions CI run
   - Use: `gh run list --repo JuliaComputing/LLMBenchMCPServer.jl --branch master --limit 1` to find the run
   - Use: `gh run watch <run-id> --repo JuliaComputing/LLMBenchMCPServer.jl --exit-status` to monitor it (can take up to 10 minutes)
   - If it fails, investigate and fix before considering the task complete

## Testing

Always run tests before pushing:
```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Package Structure

- `src/LLMBenchMCPServer.jl` - Main module file
- `src/server.jl` - Server configuration and creation
- `src/tools/` - LLM benchmark-specific tools
  - `setup_problem.jl` - Problem setup tool
  - `grade_problem.jl` - Grading tool

## Dependencies

This package depends on:
- `ClaudeMCPTools.jl` - Core MCP server implementation
- `LLMBenchSimple.jl` (optional, for testing) - Simple benchmark definitions

## Creating Benchmark Modules

Benchmark modules should export:
- `setup_problem(workdir::String)` - Returns problem description
- `grade(workdir::String, transcript::String)` - Returns grading result

## Running as MCP Server

```julia
using LLMBenchMCPServer

# With custom functions
server = LLMBenchServer(
    setup_fn=my_setup,
    grade_fn=my_grade
)

# Or with a module
LLMBenchMCPServer.main("MyBenchmarkModule")
```