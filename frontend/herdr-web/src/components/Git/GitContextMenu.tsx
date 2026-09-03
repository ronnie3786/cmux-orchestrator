import { useEffect, useRef, type KeyboardEvent } from "react";
import { Copy, FolderOpen, Minus, Plus, SquarePen } from "lucide-react";
import type { GitSection } from "../../api/git";
import { gitOpenFile } from "../../api/git";
import { isHostLocal } from "../../api/client";
import { showToast } from "../../lib/toast";
import { useGitStore } from "../../store/gitStore";

export interface GitContextTarget {
  x: number;
  y: number;
  path: string;
  section: GitSection;
  /** Absolute repository root, sent as the mutation precondition. */
  rootPath: string;
}

interface GitContextMenuProps {
  paneId: string;
  target: GitContextTarget;
  onClose: () => void;
}

async function copyPath(path: string): Promise<void> {
  try {
    if (navigator.clipboard?.writeText !== undefined) {
      await navigator.clipboard.writeText(path);
    } else {
      const textarea = document.createElement("textarea");
      textarea.value = path;
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      const copied = document.execCommand("copy");
      textarea.remove();
      if (!copied) throw new Error("Copy is unavailable");
    }
    showToast(`Copied ${path}`);
  } catch {
    showToast("Couldn't copy file path");
  }
}

/**
 * Opens (or reveals) the file on the harness machine. Only the machine in
 * front of the user can meaningfully show it, so remote panes decline with a
 * notice instead of popping windows on someone else's screen.
 */
async function openOnMachine(
  paneId: string,
  target: GitContextTarget,
  reveal: boolean,
): Promise<void> {
  if (!isHostLocal()) {
    showToast("This file is on a remote machine — opening it there isn't available yet");
    return;
  }
  try {
    await gitOpenFile(paneId, target.path, target.rootPath, reveal);
    showToast(reveal ? `Revealed ${target.path}` : `Opened ${target.path}`);
  } catch (error) {
    showToast(error instanceof Error && error.message !== "" ? error.message : "Couldn't open the file");
  }
}

export function GitContextMenu({ paneId, target, onClose }: GitContextMenuProps) {
  const menuRef = useRef<HTMLDivElement>(null);
  const stageLabel = target.section === "staged" ? "Unstage file" : "Stage file";

  useEffect(() => {
    menuRef.current?.querySelector<HTMLButtonElement>("[role='menuitem']")?.focus();
    const closeOutside = (event: PointerEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) onClose();
    };
    const closeOnViewportChange = () => onClose();
    document.addEventListener("pointerdown", closeOutside);
    window.addEventListener("resize", closeOnViewportChange);
    window.addEventListener("blur", closeOnViewportChange);
    return () => {
      document.removeEventListener("pointerdown", closeOutside);
      window.removeEventListener("resize", closeOnViewportChange);
      window.removeEventListener("blur", closeOnViewportChange);
    };
  }, [onClose]);

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const items = [...(menuRef.current?.querySelectorAll<HTMLButtonElement>("[role='menuitem']") ?? [])];
    const currentIndex = items.indexOf(document.activeElement as HTMLButtonElement);
    const delta = event.key === "ArrowDown" ? 1 : -1;
    const nextIndex = (currentIndex + delta + items.length) % items.length;
    items[nextIndex]?.focus();
  };

  const left = Math.max(8, Math.min(target.x, window.innerWidth - 202));
  const top = Math.max(8, Math.min(target.y, window.innerHeight - 190));

  return (
    <div
      ref={menuRef}
      className="hz-git-context-menu"
      role="menu"
      aria-label={`Actions for ${target.path}`}
      style={{ left, top }}
      onKeyDown={onKeyDown}
    >
      <button
        type="button"
        role="menuitem"
        onClick={() => {
          void openOnMachine(paneId, target, false);
          onClose();
        }}
      >
        <SquarePen size={14} aria-hidden />
        <span>Open file</span>
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => {
          void openOnMachine(paneId, target, true);
          onClose();
        }}
      >
        <FolderOpen size={14} aria-hidden />
        <span>Open in Finder</span>
      </button>
      <div className="hz-git-context-rule" role="separator" />
      <button
        type="button"
        role="menuitem"
        onClick={() => {
          if (target.section === "staged") {
            void useGitStore.getState().unstage(paneId, target.path);
          } else {
            void useGitStore.getState().stage(paneId, target.path);
          }
          onClose();
        }}
      >
        {target.section === "staged" ? (
          <Minus size={14} aria-hidden />
        ) : (
          <Plus size={14} aria-hidden />
        )}
        <span>{stageLabel}</span>
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => {
          void copyPath(target.path);
          onClose();
        }}
      >
        <Copy size={14} aria-hidden />
        <span>Copy path</span>
      </button>
    </div>
  );
}