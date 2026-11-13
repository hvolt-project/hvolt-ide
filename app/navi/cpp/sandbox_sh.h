// The sandbox shell: command dispatch against the application's own files.
#ifndef HVOLT_SANDBOX_SH_H
#define HVOLT_SANDBOX_SH_H

#include <string>

struct ShellState {
    std::string cwd;
    std::string lastError;
};

// Runs one command line. The working directory lives in `state` and is returned to the caller.
std::string SandboxShellRun(const std::string &line, ShellState &state);

#endif
