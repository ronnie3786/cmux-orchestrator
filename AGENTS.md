# Herdr Delivery Workflow

## Follow Through on Requested Deployments

- When the user explicitly asks to deploy Herdr to the Work Mac, treat a successful, verified deployment as the target outcome. A failing test, build error, configuration issue, or similar blocker is work to diagnose and resolve, not the default stopping point.
- Work through deployment blockers autonomously within the authorized scope. Fix the root cause in tests, application code, build configuration, or deployment tooling as appropriate, rerun the required verification, and continue the deployment workflow.
- Do not bypass, disable, or weaken legitimate safety checks merely to make the deployment green. Repair flaky or incorrectly isolated tests when needed while preserving their intended coverage.
- Keep moving until the requested deployment and its health checks succeed. Stop only when progress genuinely requires new user authority, an external state change, or a material product decision that cannot be inferred safely. If that happens, report the exact blocker and the work already completed.

## Post-Delivery Feature Recap

- After a substantial Herdr update is deployed to the Work Mac or a new Herdr iOS build is delivered, include a concise feature recap in the final response.
- For each notable user-facing feature, state what changed and provide a one-line instruction for how to test or find it. This recap is required even when implementation took several turns or hours.
- Also report the delivered version or commit and the verification result so the user can identify exactly what is installed.
