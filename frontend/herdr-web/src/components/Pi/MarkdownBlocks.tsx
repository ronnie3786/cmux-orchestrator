/**
 * Renders `PiMarkdownBlock[]` (from the ported parser) into a FIXED set of
 * React elements — paragraph, heading, list item (with marker), code block,
 * blockquote, table, horizontal rule. Inline runs render as nested
 * spans/strong/em/code/a. Security: nothing is ever injected as HTML; the
 * only interactive element is <a> restricted to http(s)/mailto URLs.
 */
import type { ReactNode } from "react";
import { parsePiMarkdown } from "../../pi/markdown";
import type { PiMarkdownColumnAlignment, PiMarkdownBlock, PiMarkdownListItem } from "../../pi/types";

export function MarkdownText({ text }: { text: string }) {
  return <MarkdownBlocks blocks={parsePiMarkdown(text)} />;
}

export function MarkdownBlocks({ blocks }: { blocks: PiMarkdownBlock[] }) {
  return (
    <>
      {blocks.map((block) => (
        <MarkdownBlock key={block.id} block={block} />
      ))}
    </>
  );
}

function MarkdownBlock({ block }: { block: PiMarkdownBlock }) {
  switch (block.kind) {
    case "paragraph":
      return <p className="hz-md-p">{renderInline(block.text)}</p>;
    case "heading": {
      const level = Math.min(6, Math.max(1, block.level));
      const Tag = (`h${level}` as unknown) as "h1";
      return <Tag className={`hz-md-h hz-md-h-${level}`}>{renderInline(block.text)}</Tag>;
    }
    case "code":
      return (
        <pre className="hz-md-pre">
          <code className="hz-md-code" data-language={block.language ?? ""}>
            {block.code}
          </code>
        </pre>
      );
    case "list":
      return (
        <ul className="hz-md-list">
          {block.items.map((item, index) => (
            <ListItem key={index} item={item} />
          ))}
        </ul>
      );
    case "quote":
      return (
        <blockquote className="hz-md-quote">
          {block.text
            .split(/\n{2,}/)
            .filter((part) => part.trim() !== "")
            .map((part, index) => (
              <p key={index}>{renderInline(part)}</p>
            ))}
        </blockquote>
      );
    case "table":
      return (
        <table className="hz-md-table">
          <thead>
            <tr>
              {block.table.headers.map((header, index) => (
                <th key={index} style={{ textAlign: textAlign(block.table.alignments[index]) }}>
                  {renderInline(header)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {block.table.rows.map((row, rowIndex) => (
              <tr key={rowIndex}>
                {row.map((cell, cellIndex) => (
                  <td key={cellIndex} style={{ textAlign: textAlign(block.table.alignments[cellIndex]) }}>
                    {renderInline(cell)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      );
    case "thematicBreak":
      return <hr className="hz-md-hr" />;
  }
}

function textAlign(
  alignment: PiMarkdownColumnAlignment | undefined,
): "left" | "center" | "right" {
  if (alignment === "center") return "center";
  if (alignment === "trailing") return "right";
  return "left";
}

function ListItem({ item }: { item: PiMarkdownListItem }) {
  const marker =
    item.marker.kind === "bullet"
      ? "•"
      : item.marker.kind === "number"
        ? `${item.marker.value}.`
        : item.marker.isCompleted
          ? "☑"
          : "☐";
  const markerClass =
    item.marker.kind === "task"
      ? `hz-md-marker hz-md-marker-${item.marker.isCompleted ? "done" : "todo"}`
      : "hz-md-marker";
  return (
    <li
      className="hz-md-item"
      style={{ marginLeft: item.depth * 18 }}
    >
      <span className={markerClass} aria-hidden>
        {marker}
      </span>
      <span className="hz-md-item-text">{renderInline(item.text)}</span>
    </li>
  );
}

// ---------------------------------------------------------------------------
// Inline runs: `code`, **bold**, *italic*, _italic_, [text](url) —
// everything else is plain text. Unknown markup is rendered literally.
// ---------------------------------------------------------------------------

const INLINE_TOKEN =
  /(`[^`\n]+`)|(\*\*[^*]+?\*\*)|(\[[^\]]+\]\([^()\s]+\))|(\*[^*\n]+?\*)|(_[^_\n]+?_)/g;

function renderInline(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let position = 0;
  let key = 0;
  while (position < text.length) {
    const rest = text.slice(position);
    INLINE_TOKEN.lastIndex = 0;
    const match = INLINE_TOKEN.exec(rest);
    if (match === null) {
      nodes.push(<span key={key++}>{rest}</span>);
      break;
    }
    if (match.index > 0) {
      nodes.push(<span key={key++}>{rest.slice(0, match.index)}</span>);
    }
    const token = match[0];
    if (match[1] !== undefined) {
      nodes.push(
        <code key={key++} className="hz-md-code-inline">
          {token.slice(1, -1)}
        </code>,
      );
    } else if (match[2] !== undefined) {
      nodes.push(<strong key={key++}>{renderInline(token.slice(2, -2))}</strong>);
    } else if (match[3] !== undefined) {
      nodes.push(renderLink(token, key++));
    } else if (match[4] !== undefined || match[5] !== undefined) {
      nodes.push(<em key={key++}>{renderInline(token.slice(1, -1))}</em>);
    } else {
      // Unreachable: the regex only matches one of the five groups.
      nodes.push(<span key={key++}>{token}</span>);
    }
    position += match.index + token.length;
  }
  return nodes;
}

function renderLink(token: string, key: number): ReactNode {
  const match = /^\[([^\]]+)\]\(([^()\s]+)\)$/.exec(token);
  if (match === null || !/^(https?:|mailto:)/i.test(match[2])) {
    return <span key={key}>{token}</span>;
  }
  return (
    <a key={key} href={match[2]} target="_blank" rel="noopener noreferrer">
      {renderInline(match[1])}
    </a>
  );
}
