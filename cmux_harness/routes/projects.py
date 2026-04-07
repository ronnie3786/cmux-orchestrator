from __future__ import annotations

from .. import objectives


def handle_list_projects(handler):
    handler._json_response(objectives.list_projects())


def handle_get_project(handler, project):
    handler._json_response(project)


def handle_post_create_project(handler, data):
    root_path = data.get("rootPath", "")
    name = data.get("name", "")
    default_base_branch = data.get("defaultBaseBranch")
    try:
        project = objectives.create_project(
            name=name,
            root_path=root_path,
            default_base_branch=default_base_branch or "main",
        )
    except ValueError as exc:
        message = str(exc)
        status = 409 if "already exists" in message else 400
        handler._json_response({"ok": False, "error": message}, status)
        return
    handler._json_response(project, 201)


def handle_patch_project(handler, project_id, data):
    try:
        project = objectives.update_project(project_id, data)
    except FileNotFoundError:
        handler._json_response({"ok": False, "error": "project not found"}, 404)
        return
    except ValueError as exc:
        message = str(exc)
        status = 409 if "already exists" in message else 400
        handler._json_response({"ok": False, "error": message}, status)
        return
    handler._json_response(project)


def handle_delete_project(handler, project_id):
    try:
        deleted = objectives.delete_project(project_id)
    except ValueError as exc:
        handler._json_response({"ok": False, "error": str(exc)}, 409)
        return
    if not deleted:
        handler._json_response({"ok": False, "error": "project not found"}, 404)
        return
    handler._json_response({"ok": True})
