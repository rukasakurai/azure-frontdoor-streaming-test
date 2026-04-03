---
description: Test Markdown file content by executing step-by-step instructions
mode: 'agent'
argument-hint: "Specify the Markdown file to test"
---

# Test Markdown File Content

This prompt helps you test the content of Markdown files, particularly those containing step-by-step instructions for various workflows.

## Target File

Test the Markdown file: **${input:markdownFile:README.md}**

## Instructions

### Non-Negotiables (must follow)

1. **Execute in order**: Treat the Markdown file as an ordered procedure. Start at the top and execute every step sequentially.
2. **Execute, don’t simulate**: Every command/code snippet must be run in the provided environment unless it is explicitly marked as manual/GUI-only.
3. **Manual/GUI/auth steps are blocking**: The moment a step requires user action (login, portal clicks, secrets entry, approvals), stop and hand back to the user with: "Please complete X and reply 'done'."
  - Do not proceed to later steps until the user replies "done".
4. **Destructive steps require explicit confirmation**: If a step creates/changes/deletes external resources (cloud resources, RBAC, app registrations, billing-impacting actions), ask the user to confirm before running it.
5. **Record evidence**: For each executed command, record: the exact command run, whether it succeeded, and key output needed to validate the step.
6. **Accurate environment reporting**: Use the actual environment context (OS + shell) from the current session; do not guess.
  - The `OS:` field must include a specific version (and build where applicable), e.g. `Windows 11 23H2 (build 22631.XXXX)`.
  - The `Shell:` field must include shell name **and** version/edition where applicable, e.g. `PowerShell 7.4.1 (Core)` vs `Windows PowerShell 5.1 (Desktop)`.
  - Record evidence for how you determined OS/shell details (for example, `winver` / `ver`, `$PSVersionTable`, `bash --version | head -n 1`).
7. **Accurate attribution**: If the run included any manual/GUI/auth steps, do not imply it was fully automated.
  - Keep the `Tester:` line in the required schema, but reflect reality in its value (e.g., `Automated Documentation Tester (with human intervention)`), and/or clearly state the human steps in `Notes:`.
  - `Notes:` must explicitly list what the human did (e.g., "entered repo variables/secrets", "approved RBAC assignment", "clicked Run workflow").

1. **Read and Analyze**: 
   - Carefully read through the entire Markdown file specified above
   - Identify all step-by-step instructions, commands, and procedures
   - Note any prerequisites or setup requirements

2. **Verify Content is Up-to-Date**:
   - Use web search to check if technologies, tools, and approaches mentioned are current
   - Verify that versions referenced are still supported and not deprecated
   - Check if any recommended practices have been superseded by newer approaches
   - Identify any deprecated commands, APIs, or methodologies
   - **Do not edit yet**: only note suspected outdated items at this stage.
   - **After execution attempts**, update the target Markdown file to fix any outdated content found:
     - Replace deprecated commands with current alternatives
     - Update version numbers to latest stable versions
     - Replace outdated practices with current recommended approaches
     - Add notes about breaking changes if applicable
   - Document all updates made in your final report

3. **Execute Steps**:
   - Follow each instruction in the Markdown file sequentially (no re-ordering)
   - For each step:
     - Quote the step you are executing (short excerpt)
     - Run the commands exactly as written
     - Verify the expected outcome (or capture the actual outcome)
     - If it fails due to doc error, apply the smallest possible fix in the Markdown and rerun
   - **For steps requiring manual intervention** (authentication, GUI operations, user-specific input):
     - Document which step requires manual action
     - **Hand back to the user** with clear instructions: "Please complete [specific action] and reply 'done' when ready"
     - **Wait for user confirmation** before proceeding to next steps
     - Mark these steps as "Requires Manual Intervention" in your report
   - **For steps that modify external resources** (creating apps/SPs, role assignments, resource creation):
     - Ask for explicit user confirmation before running them
     - If not confirmed, mark the step as "Requires Manual Intervention" and stop
   - Pay attention to:
     - Command syntax and correctness
     - Actual command execution and output
     - File paths and references
     - Logical flow and dependencies between steps
     - Missing or incomplete instructions
   - **Do not skip steps** - attempt execution or request user assistance

4. **Issue Handling**:
   - **For simple issues** (typos, minor command errors, outdated syntax):
     - Fix the issue immediately in the Markdown file
     - Document what was fixed in your response
   
   - **For complex issues** (architectural problems, missing major steps, requires significant changes):
     - Do NOT attempt to fix
     - Create a detailed GitHub issue with:
       - Clear title describing the problem
       - Description of what went wrong
       - Which step(s) failed
       - Expected vs actual behavior
       - Any error messages or logs
       - Suggestions for resolution if applicable

5. **Update the Target Markdown File with Test History**:
  - After running the test (regardless of outcome), update the *target Markdown file itself* with a new entry under `## Documentation Test History`
  - Use today's date in ISO format: `YYYY-MM-DD`
  - Set `Result` to match the overall status: `PASS` / `PASS with manual steps` / `PASS with fixes` / `PARTIAL` / `FAIL`
  - If the file already contains a section titled `## Documentation Test History`, add a new entry (do not replace existing history)
  - Otherwise, append the section to the end of the file
  - Use the `Notes` field to capture any key blockers or manual steps (for example, authentication required, org policy blocks, or missing permissions)
  - The section must be exactly in this format:

      ```
      ## Documentation Test History
      ### YYYY-MM-DD
      - Result: PASS / PASS with manual steps / PASS with fixes / PARTIAL / FAIL
      - Platform/Context: [e.g., Microsoft Surface Laptop X, GitHub Codespaces (Dev Container), Azure Cloud Shell]
      - OS: [Operating System and version/build]
      - Shell: [Shell name + version/edition]
        - Tester: Automated Documentation Tester
      - Notes: [Optional: Key findings or manual steps required]
      ```

      - If there was any human intervention, keep the `Tester:` key but update the value to reflect that (for example: `Automated Documentation Tester (with human intervention)`) and describe the human steps in `Notes:`.

6. **Report Results**:
   - Summarize which steps passed and which failed
   - List any fixes made
   - Provide links to any GitHub issues created
   - Note any improvements or clarifications that could enhance the documentation

## Testing Approach

- **Execute, don't just validate**: Actually run commands and verify outputs, don't just check syntax
- **Request user help proactively**: When encountering authentication, GUI steps, or user-specific configuration, immediately hand back to the user with clear instructions
- **Test in context**: Use the actual environment available (dev container, installed tools, etc.)
- **Stop on blockers**: Do not continue past a blocking manual step until the user replies "done".
- **Prefer minimal edits**: Fix only what prevents correct execution and accuracy.
- Document any assumptions made during testing
- Verify that prerequisites listed in the file are accurate and sufficient
- Check for consistency with other documentation in the repository
- Ensure commands work across different platforms if the guide claims cross-platform support
- **Be thorough**: Better to request manual intervention than to skip steps

## Common Manual Intervention Scenarios

When you encounter these, hand back to the user:
- **Authentication flows** (`az login`, OAuth flows, browser-based auth)
- **GUI operations** (GitHub repository settings, Azure Portal navigation)
- **User-specific values** (when actual tenant IDs, subscription IDs, etc. are needed - not placeholder validation)
- **External service verification** (checking if a deployed service is accessible)
- **Interactive prompts** that require human decision-making

## Output Format

Provide your test results in the following format:

```
### Test Results for [filename]

**Overall Status**: ✅ PASS / ⚠️ PASS with manual steps / ⚠️ PASS with fixes / 🔄 PARTIAL / ❌ FAIL

**Steps Tested**: [number]
**Steps Passed**: [number]
**Steps Requiring Manual Intervention**: [number]
**Steps Fixed**: [number]
**Issues Created**: [number]

#### Manual Steps Required
- [List steps that required user intervention with what was needed]

#### Updates for Outdated Content
- [List any updates made to ensure content is current]

#### Fixes Applied
- [List any quick fixes made to the file]

#### Issues Found
- [List complex issues that require GitHub issues]

#### GitHub Issues Created
- [Link to issue 1]
- [Link to issue 2]

#### Recommendations
- [Any suggestions for improving the documentation]

#### Execution Log (Required)
- [Step-by-step list of each command you ran and whether it succeeded]
```

## Notes

- This prompt is designed for testing instructional Markdown files with **actual execution**
- Always prioritize accuracy and reproducibility in your testing
- **Do not skip steps** - either execute them or request user assistance
- When in doubt about whether to fix or create an issue, prefer creating an issue for visibility
- Consider the impact on users who will follow these instructions
- **Interactive testing is expected**: You will need to collaborate with the user for manual steps
- Mark documentation as PARTIAL if you cannot complete testing due to missing manual inputs