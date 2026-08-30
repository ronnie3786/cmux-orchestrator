# agenttrail technique cookbook (verbatim recipes to transplant)

Extracted from agenttrail's public/index.html. Use these exact mechanics
(re-inked in Herdr's Catppuccin tokens — never agenttrail's amber palette).

## Easings & the two-speed motion system
```css
--ease: cubic-bezier(0.32,0.72,0,1);      /* 700ms — ambient hover/state on big surfaces */
--ease-out: cubic-bezier(0.23,1,0.32,1);  /* 250ms — small controls, accordions, chevrons */
```
Press states: buttons `:active{transform:scale(.98)}`, icons `.96`, rows `.99`.

## Keyframes
```css
@keyframes working-pulse { 50% { opacity:.35 } }              /* 1.6s ease-in-out infinite, every live dot */
@keyframes breathe { from{opacity:.4;transform:scale(.65)} to{opacity:1;transform:scale(1)} } /* 1800ms alternate */
@keyframes reveal  { from{opacity:0;transform:translateY(16px);filter:blur(4px)}
                     to{opacity:1;transform:none;filter:blur(0)} }   /* entries; stagger delay = index*80ms inline */
@keyframes travel  { to { stroke-dashoffset:-26 } }           /* marching ants; -26 = 2*(5+8) seamless */
@keyframes capsule-spin { to{transform:rotate(360deg)} }      /* with transform-box:fill-box; transform-origin:center */
@keyframes capsule-pop  { from{opacity:0;transform:scale(.95)} to{opacity:1;transform:none} }
@keyframes rail-live    { from{opacity:.5} to{opacity:1} }    /* shimmer on active progress segment */
```
Reduced motion: `@media (prefers-reduced-motion: reduce){ *{animation-duration:1ms!important;animation-iteration-count:1!important;transition-duration:1ms!important} }`

## Edge dash grammar (all with vector-effect: non-scaling-stroke)
- dependency/traveled: solid 1.5–2.5px, optional small arrowhead in a QUIET color
- soft link / future: `stroke-dasharray:2 7; stroke-linecap:round` (dotted thread)
- live flow: `stroke-dasharray:5 8` + travel animation, accent color
- session trail: polyline `stroke-width:2.5; stroke-dasharray:1 7; round caps`,
  agent color, opacity .55 live / .2 ended

## Declared vs observed (the honesty channel)
Status icon shows DECLARED state (spinner arc `stroke-dasharray="16 41"`,
capsule-spin 1100ms). An independent `obs-ring` circle (r=13, accent,
`stroke-dasharray="23 59"`, spinning at 1300ms — deliberately out of phase)
plus a verb label ("Editing"/"Revising") + filename with live ago appears ONLY
while real activity is <60s old. Opacity 0→1 transition 400ms on class flip.

## Structure rebuilds, time mutates
Every timestamp is `<span class="t-ago" data-at="1724968000000"></span>`;
`setInterval(renderTimes,1000)` sets textContent = ago(at) ("3s","5 min","2 h").
Expensive re-renders are gated by comparing a key/string; volatile time NEVER
triggers rebuilds. Live class flips (obs-live, hot) also happen in the 1s tick.

## Accordions without heights
```css
.detail { display:grid; grid-template-rows:0fr; opacity:0; transition:250ms var(--ease-out) }
.open > .detail { grid-template-rows:1fr; opacity:1 }
.detail > * { overflow:hidden }
```

## Spinner ring with number (active task marker)
24px ring: `.ring-track` circle in hairline color under `.ring-live` accent arc
(`stroke-dasharray:"19.35 49.76"` ≈ 28% arc, capsule-spin 1100ms linear), with
the sequence number centered inside. Done = 22px filled circle + white check
(entering with capsule-pop). Blocked = same badge in alert with "!".

## Camera (option A only)
```js
// wheel = pan; cmd/ctrl+wheel = zoom to cursor (world-point invariant):
const wx=(px-panX)/zoom, wy=(py-panY)/zoom;
zoom=clamp(zoom*Math.exp(-e.deltaY*0.002), .25, 2.5);
panX=px-wx*zoom; panY=py-wy*zoom;
// flight: world.style.transition='transform 600ms cubic-bezier(.23,1,.32,1)';
// set pan/zoom; setTimeout(()=>world.style.transition='',650);
```
Pointer-capture drag pan (skip when e.target.closest('.gnode,.overlay-card')).
Minimap: 150px wide, item rects colored by status, viewport rect synced on
every transform, click-to-jump. LOD with hysteresis (collapse <0.45, restore
>0.55) so nothing flaps at the boundary.

## Ambient texture
```html
<!-- dot grid under the world -->
<svg class="grid"><defs><pattern id="dots" width="24" height="24" patternUnits="userSpaceOnUse">
<circle cx="1.5" cy="1.5" r="1" fill="rgba(166,173,200,.14)"/></pattern></defs>
<rect width="100%" height="100%" fill="url(#dots)" opacity=".35"/></svg>
```
Grain: fixed full-viewport div, background = data-URI SVG with
`<feTurbulence type="fractalNoise" baseFrequency=".9"/>`, opacity .025,
pointer-events none.

## Run card anatomy (live session overlay)
340px, radius 14, shadow 0 12px 40px rgba(0,0,0,.8), reveal entry.
Head: agent mark · name 600 13px · "· project" faint 11.5 · 6px breathing
success dot · right-aligned elapsed + "in <component>" accent link (flies
camera / scrolls). Task line 12.5px ellipsized. Tool line mono 11.5:
`<span class="tn">Edit</span> <span class="td">path</span> <span class="ta">3s</span>`
(tn=accent, td=ellipsized, ta=faint tabular). Click opens history: last 5
tools, durations right-aligned (`ms>1200 ? Xs : Xms`). Ended: dot goes static
faint, card opacity dims — death is a dimming, not a removal.

## foreignObject (option A)
SVG world keeps cards/edges cheap; real text layout (stage capsule lists)
lives in `<foreignObject>` hosting normal HTML that shares page CSS and the
world transform. Give it explicit width and generous height.

## Toast
Fixed bottom-center card (--elevated, radius 12, shadow), rises 8px while
fading in, role="status", auto-dismiss 2.6s with the timeout handle stored on
the element so rapid toasts reset cleanly.
