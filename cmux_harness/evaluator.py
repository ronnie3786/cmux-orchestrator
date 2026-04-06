import os
import shutil
import subprocess
import tempfile


def is_maestro_available():
    return shutil.which("maestro") is not None


def run_tier1_build(workspace_uuid, cmux_api_module):
    """Send /exp-project-run to the worker session. Returns (passed, output)."""
    try:
        ok = cmux_api_module.send_prompt_to_workspace(workspace_uuid, "/exp-project-run")
        return (True, "Build command sent") if ok else (False, "Failed to send build command")
    except Exception as e:
        return False, str(e)


def generate_maestro_flow(contract_text, app_id="com.example.app"):
    """Generate Maestro YAML from contract acceptance criteria."""
    lines = [f"appId: {app_id}", "---", "- launchApp"]
    for line in contract_text.splitlines():
        stripped = line.strip()
        if stripped and (stripped[0].isdigit() or stripped.startswith("-")):
            criterion = stripped.lstrip("0123456789.-) ").strip()
            if criterion:
                lines.append(f"# Criterion: {criterion}")
                words = [w for w in criterion.split() if len(w) > 3 and w[0].isupper()]
                if words:
                    lines.append(f"- assertVisible: \"{words[0]}\"")
    return "\n".join(lines)


def run_tier2_maestro(flow_yaml, platform="ios"):
    """Run maestro test. Returns (passed, output). Skips if maestro not installed."""
    if not is_maestro_available():
        return True, "Maestro not available - skipped"
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        f.write(flow_yaml)
        flow_path = f.name
    try:
        result = subprocess.run(
            ["maestro", "test", flow_path, f"--platform={platform}"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        return result.returncode == 0, (result.stdout or "") + (result.stderr or "")
    except Exception as e:
        return False, str(e)
    finally:
        try:
            os.unlink(flow_path)
        except OSError:
            pass
