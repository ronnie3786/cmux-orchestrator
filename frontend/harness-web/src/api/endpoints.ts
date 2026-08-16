import { apiRequest } from "./client";

export type WorkspaceAutoMode = "off" | "auto" | "super";

/** Mirrors Workspace in cmux-harness-ios Models/WorkspaceModels.swift. */
export interface Workspace {
  hasClaude: boolean;
  index: number;
  name: string;
  uuid: string;
  enabled: boolean;
  autoMode?: WorkspaceAutoMode | null;
  starred?: boolean;
  autoEnabledAt?: number | null;
  autoExpiresAt?: number | null;
  customName?: string | null;
  lastCheck?: string | null;
  screenTail?: string | null;
  screenFull?: string | null;
  cwd?: string | null;
  branch?: string | null;
  sessionStart?: number | null;
  sessionCost?: string | null;
  surfaceId?: string | null;
  surfaceUuid?: string | null;
  surfaceLabel?: string | null;
  surfaceTitle?: string | null;
  gitDirty?: boolean | null;
  surfaceCreatedAt?: string | null;
  surfaceAge?: number | null;
}

/** Mirrors HarnessStatus in cmux-harness-ios Models/WorkspaceModels.swift. */
export interface HarnessStatus {
  enabled: boolean;
  workspaces: Workspace[];
  pollInterval: number;
  socketFound: boolean;
  model?: string | null;
  reviewEnabled?: boolean | null;
  reviewModel?: string | null;
  reviewBackend?: string | null;
  contractReviewEnabled?: boolean | null;
  connected?: boolean | null;
  lastSuccessfulPoll?: number | null;
  connectionLostAt?: number | null;
  staleData?: boolean | null;
  ollamaAvailable?: boolean | null;
}

export function getStatus(): Promise<HarnessStatus> {
  return apiRequest<HarnessStatus>("/api/status");
}
