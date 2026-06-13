# Casablanca Design System
## A Native SwiftUI macOS Meeting Assistant

> Design philosophy: **Calm precision.** Casablanca should feel like a trusted colleague who sits quietly in the background, captures everything, and presents it with clarity. The interface disappears during meetings and shines when reviewing.

---

## 1. Design Principles

1. **Dark-first, light-ready** — Dark mode is the primary design target. Light mode is fully supported but derived from dark mode decisions.
2. **Content over chrome** — Minimize UI decoration. Let meeting content, transcripts, and notes breathe.
3. **Keyboard-native** — Every action reachable via keyboard. Visual affordances for mouse users, speed for keyboard users (inspired by Linear, Raycast).
4. **State-aware** — The UI clearly communicates what the app is doing: idle, recording, processing, reviewing.
5. **Information density** — Compact but not cramped. Inspired by Linear's approach: modular components that present content optimally without rigid grid constraints.
6. **Native-first** — Use system materials, vibrancy, and SF Pro. Feel like macOS, not a web app in a wrapper.

---

## 2. Color System

### 2.1 Foundation — Neutral Palette (Dark Mode Primary)

Use semantic color tokens, not raw hex values. Define three core variables per theme (inspired by Linear's approach using LCH color space for perceptual uniformity):

| Token | Dark Mode | Light Mode | Usage |
|---|---|---|---|
| `background.primary` | `#0D0D0F` | `#FFFFFF` | Main app background |
| `background.secondary` | `#141416` | `#F7F7F8` | Sidebar, panels |
| `background.tertiary` | `#1C1C1E` | `#EFEFF1` | Cards, elevated surfaces |
| `background.hover` | `#232326` | `#E8E8EA` | Interactive hover states |
| `background.active` | `#2C2C2E` | `#DFDFE1` | Active/pressed states |

### 2.2 Text & Foreground

| Token | Dark Mode | Light Mode | Usage |
|---|---|---|---|
| `text.primary` | `#ECECEF` | `#1A1A1C` | Headlines, primary content |
| `text.secondary` | `#A0A0A8` | `#6B6B73` | Subtitles, metadata, timestamps |
| `text.tertiary` | `#5C5C66` | `#9C9CA3` | Placeholders, disabled text |
| `text.inverse` | `#1A1A1C` | `#ECECEF` | Text on accent backgrounds |

### 2.3 Border & Separator

| Token | Dark Mode | Light Mode | Usage |
|---|---|---|---|
| `border.subtle` | `#1F1F23` | `#E5E5E8` | Card borders, dividers |
| `border.default` | `#2A2A2E` | `#D1D1D6` | Input fields, containers |
| `border.focus` | `#5B6EF5` | `#4A5CE6` | Focused input ring |

### 2.4 Accent Colors

| Token | Value | Usage |
|---|---|---|
| `accent.primary` | `#5B6EF5` (Indigo) | Primary actions, links, active nav |
| `accent.primaryHover` | `#4A5CE6` | Hover state for primary accent |
| `accent.secondary` | `#8B5CF6` (Violet) | Secondary highlights, AI-generated |
| `accent.success` | `#34D399` (Emerald) | Success states, completed items |
| `accent.warning` | `#FBBF24` (Amber) | Warnings, attention needed |
| `accent.danger` | `#EF4444` (Red) | Destructive actions, errors |

### 2.5 Semantic / State Colors

| Token | Value | Usage |
|---|---|---|
| `state.recording` | `#EF4444` | Recording indicator (pulsing) |
| `state.processing` | `#8B5CF6` | AI processing indicator |
| `state.live` | `#34D399` | Live/connected status |
| `state.idle` | `#5C5C66` | Inactive/idle status |
| `state.aiGenerated` | `#8B5CF6` at 15% opacity | Background tint for AI content |

### 2.6 Material & Translucency

Use native SwiftUI materials for layered surfaces:

```swift
// Sidebar background
.background(.ultraThinMaterial)

// Floating panels / popovers
.background(.thinMaterial)

// Toolbar areas
.background(.bar)

// Card overlays
.background(.regularMaterial)
```

Vibrancy is automatic when using `.background(Material)` on macOS — foreground content adapts to pull color from the background, enhancing depth.

---

## 3. Typography

### 3.1 Type Scale (SF Pro)

All typography uses **SF Pro** (the system font). Use SwiftUI's built-in text styles for Dynamic Type support, with specific customizations:

| Style Name | SwiftUI Style | Size/Weight | Line Height | Usage |
|---|---|---|---|---|
| `display` | `.largeTitle` | 28pt / Bold | 34pt | App title, onboarding headers |
| `heading1` | `.title` | 22pt / Semibold | 28pt | Section headers, meeting titles |
| `heading2` | `.title2` | 18pt / Semibold | 24pt | Card titles, panel headers |
| `heading3` | `.title3` | 15pt / Medium | 20pt | Subsection headers |
| `body` | `.body` | 13pt / Regular | 18pt | Primary content, transcript text |
| `bodyMedium` | `.body` | 13pt / Medium | 18pt | Emphasized body text |
| `caption` | `.caption` | 11pt / Regular | 14pt | Timestamps, metadata, labels |
| `captionMedium` | `.caption` | 11pt / Medium | 14pt | Badge labels, tab labels |
| `footnote` | `.footnote` | 12pt / Regular | 16pt | Secondary info, helper text |
| `mono` | `.body` + monospaced | 12pt / Regular | 18pt | Code, technical identifiers |

### 3.2 Typography Guidelines

- **macOS-native sizing**: macOS text is physically smaller than iOS. The 13pt body is standard for Mac apps — do not upscale to iOS sizes.
- **SF Pro Display** is used automatically at 20pt+ by the system. **SF Pro Text** handles smaller sizes.
- Use **SF Pro Rounded** sparingly — only for numeric badges or playful UI elements if needed.
- Prefer **weight contrast** over size contrast for hierarchy within compact spaces.
- Use `.monospacedDigit()` for any numeric data that updates (timers, counters) to prevent layout shifts.

```swift
// Example usage
Text("Meeting Notes")
    .font(.title2)
    .fontWeight(.semibold)
    .foregroundStyle(.primary)

Text("2:34:12")
    .font(.body)
    .monospacedDigit()
    .foregroundStyle(.secondary)

Text("AI-generated summary")
    .font(.caption)
    .foregroundStyle(Color.accentSecondary)
```

---

## 4. Spacing & Layout System

### 4.1 Spacing Scale (4pt Base Grid)

All spacing derives from a 4pt base unit:

| Token | Value | Usage |
|---|---|---|
| `space.xxs` | 2pt | Tight icon-to-text gaps |
| `space.xs` | 4pt | Inline element gaps, compact padding |
| `space.sm` | 8pt | Standard inner padding, list item gaps |
| `space.md` | 12pt | Card inner padding, section gaps |
| `space.lg` | 16pt | Panel padding, group spacing |
| `space.xl` | 24pt | Section separation |
| `space.xxl` | 32pt | Major section breaks |
| `space.xxxl` | 48pt | Page-level padding, hero spacing |

### 4.2 Layout Constants

| Element | Value | Notes |
|---|---|---|
| Sidebar width | 220pt (collapsed: 60pt) | Collapsible with animation |
| Sidebar item height | 28pt | Compact, Linear-style |
| Toolbar height | 52pt | Standard macOS toolbar |
| Card corner radius | 8pt | Consistent rounded corners |
| Button corner radius | 6pt | Slightly smaller than cards |
| Input corner radius | 6pt | Matches buttons |
| Small element radius | 4pt | Tags, badges, chips |
| Content max width | 720pt | Readable line length for notes/transcript |
| Inspector panel width | 280pt | Right-side detail panel |
| Popover width | 288pt | `CasaLayout.popoverWidth` |
| Modal width — small | 460pt | `CasaLayout.modalWidthSmall` (Onboarding) |
| Modal width — medium | 520pt | `CasaLayout.modalWidthMedium` (Update prompt) |
| Modal width — large | 560pt | `CasaLayout.modalWidthLarge` (Global Search, Settings) |
| Modal width — XL | 600pt | `CasaLayout.modalWidthXL` (Action Queue) |

Sheets and modal panels use the `CasaLayout.modalWidth*` tier tokens rather than
hardcoded `.frame(width:)` values, so modal sizing stays consistent and tunable
in one place.

### 4.3 Window Layout

```
┌──────────────────────────────────────────────────────────────┐
│  Toolbar (52pt) — translucent bar material                   │
├────────────┬─────────────────────────────────────┬───────────┤
│            │                                     │           │
│  Sidebar   │       Main Content Area             │ Inspector │
│  (220pt)   │       (flexible)                    │ (280pt)   │
│            │                                     │ optional  │
│  ultra-    │  background.primary                 │           │
│  thin      │  max-width: 720pt centered          │  thin     │
│  material  │                                     │  material │
│            │                                     │           │
├────────────┴─────────────────────────────────────┴───────────┤
│  Status Bar (optional, 28pt) — recording state, connection   │
└──────────────────────────────────────────────────────────────┘
```

---

## 5. Component Specifications

### 5.1 Sidebar

**Behavior**: NavigationSplitView with `.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)`

```
Visual spec:
├── App logo/icon (16x16) + "Casablanca" label
├── Search field (compact, 28pt height)
├── ─── separator ───
├── Section: Upcoming
│   ├── Meeting item (28pt row)
│   │   ├── Status dot (6pt, left-aligned)
│   │   ├── Title (body, primary text, truncated)
│   │   └── Time (caption, secondary text, trailing)
│   └── ...
├── Section: Recent
│   └── Meeting items...
├── ─── separator ───
├── Section: Collections / Tags
│   └── Folder items with SF Symbol icons
└── ─── spacer ───
    └── Settings gear icon (bottom-pinned)
```

**Styling**:
- Background: `.ultraThinMaterial` (enables sidebar vibrancy)
- Selected item: `background.active` with `accent.primary` left edge indicator (2pt wide, rounded)
- Hover: `background.hover` with 150ms ease-in-out
- Section headers: `captionMedium`, `text.tertiary`, uppercase, 0.5pt letter spacing
- Icons: SF Symbols, 13pt, `.secondary` foreground style

### 5.2 Cards (Meeting Cards)

Meeting cards are the primary content unit — used in lists, grids, and detail views.

```
┌─────────────────────────────────────────────┐
│  ● Live  ·  10:00 AM – 11:00 AM            │  ← caption, state color + secondary
│                                             │
│  Weekly Product Sync                        │  ← heading3, primary
│  with Sarah, Mike, +3 others               │  ← footnote, secondary
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │  Key decisions: ...                 │    │  ← AI summary block (state.aiGenerated bg)
│  │  Action items: 3                    │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  📎 2 attachments  ·  ✓ 3 action items     │  ← caption, secondary + SF Symbols
└─────────────────────────────────────────────┘
```

**Styling**:
- Background: `background.tertiary`
- Border: 1pt `border.subtle`
- Corner radius: 8pt
- Inner padding: `space.md` (12pt)
- Hover: Lift with subtle shadow (`0, 2, 8, rgba(0,0,0,0.15)`) + border transitions to `border.default`
- Transition: 200ms ease-out

### 5.3 Buttons

**Primary Button**:
- Background: `accent.primary`
- Text: `text.inverse`, `bodyMedium`
- Padding: 6pt vertical, 12pt horizontal
- Corner radius: 6pt
- Hover: `accent.primaryHover`
- Active: scale(0.98) + darken 5%
- Disabled: 40% opacity

**Secondary Button**:
- Background: `background.tertiary`
- Border: 1pt `border.default`
- Text: `text.primary`, `bodyMedium`
- Hover: `background.hover`

**Ghost Button**:
- Background: transparent
- Text: `text.secondary`, `body`
- Hover: `background.hover`

**Danger Button**:
- Background: `accent.danger` at 15% opacity
- Text: `accent.danger`, `bodyMedium`
- Hover: `accent.danger` at 25% opacity

**Icon Button** (toolbar actions):
- Size: 28x28pt hit area, 16pt icon
- Background: transparent
- Hover: `background.hover`, corner radius 6pt

### 5.4 Text Fields

```
┌──────────────────────────────────────┐
│  🔍  Search meetings...              │  ← Compact search (28pt)
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│  Add a note...                       │  ← Standard input (32pt)
└──────────────────────────────────────┘
```

- Background: `background.secondary`
- Border: 1pt `border.default`
- Corner radius: 6pt
- Focus: border transitions to `border.focus` (accent.primary), subtle glow `accent.primary` at 10% opacity
- Placeholder: `text.tertiary`
- Text: `text.primary`, `body`

### 5.5 Toolbar

Use SwiftUI's `.toolbar` with customizations:

```
┌──────────────────────────────────────────────────────────┐
│  ◀ ▶  │  Weekly Product Sync        │  🔍  📤  ⚙  ● REC │
│  nav   │  title (heading3)           │  actions          │
└──────────────────────────────────────────────────────────┘
```

- Background: `.bar` material (native translucent toolbar)
- Title: `heading3` weight, centered or leading depending on context
- Icon buttons: 16pt SF Symbols, ghost button style
- Separator: 1pt `border.subtle` at bottom
- Recording indicator in toolbar: pulsing red dot + "REC" label

### 5.6 Tags & Badges

- Background: accent color at 15% opacity
- Text: accent color, `captionMedium`
- Corner radius: 4pt
- Padding: 2pt vertical, 6pt horizontal
- Max width: truncate with ellipsis

### 5.7 Context Menus & Popovers

- Background: `.regularMaterial`
- Corner radius: 8pt
- Shadow: `0, 4, 16, rgba(0,0,0,0.2)` (dark), `0, 4, 16, rgba(0,0,0,0.08)` (light)
- Border: 1pt `border.subtle`
- Item height: 28pt
- Item hover: `background.hover`
- Icons on leading edge (consistent with macOS Tahoe menu style)

---

## 6. Iconography

- **System**: SF Symbols exclusively. No custom icon library.
- **Size**: Match text size — 13pt for body context, 16pt for toolbar, 11pt for captions.
- **Weight**: Match the font weight of adjacent text.
- **Rendering**: `.hierarchical` for multi-color depth, `.monochrome` for simple UI elements.
- **Preferred symbols** (meeting-assistant context):
  - `mic.fill` / `mic.slash.fill` — microphone state
  - `record.circle` — recording
  - `waveform` — audio active
  - `person.2.fill` — participants
  - `doc.text.fill` — notes/transcript
  - `checkmark.circle.fill` — action items
  - `sparkles` — AI-generated content
  - `calendar` — schedule
  - `magnifyingglass` — search
  - `gear` — settings
  - `sidebar.left` — toggle sidebar

---

## 7. Animation & Motion

### 7.1 Core Timing Functions

| Type | Duration | Curve | Usage |
|---|---|---|---|
| Micro | 100ms | `.easeOut` | Button press, toggle |
| Fast | 150ms | `.easeInOut` | Hover states, highlight changes |
| Standard | 200ms | `.easeInOut` | Panel transitions, card expand |
| Emphasis | 300ms | `.spring(response: 0.3, dampingFraction: 0.7)` | Modal appear, sidebar toggle |
| Slow | 400ms | `.spring(response: 0.4, dampingFraction: 0.8)` | Page transitions, view switches |

### 7.2 State Transitions

**Recording State — Pulsing Indicator**:
```swift
// Red dot with infinite pulse
Circle()
    .fill(Color.stateRecording)
    .frame(width: 8, height: 8)
    .scaleEffect(isRecording ? 1.2 : 1.0)
    .opacity(isRecording ? 1.0 : 0.6)
    .animation(
        .easeInOut(duration: 1.0)
        .repeatForever(autoreverses: true),
        value: isRecording
    )
```

**Processing State — Animated Gradient**:
```swift
// Subtle shimmer/gradient sweep for AI processing
LinearGradient(
    colors: [.accentSecondary.opacity(0.1), .accentSecondary.opacity(0.3), .accentSecondary.opacity(0.1)],
    startPoint: .leading,
    endPoint: .trailing
)
.mask(content)
.offset(x: animating ? 200 : -200)
.animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: animating)
```

**Sidebar Collapse**:
```swift
withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
    isSidebarCollapsed.toggle()
}
```

**Content Appear (staggered list)**:
```swift
// Each item delays slightly more
.transition(.opacity.combined(with: .move(edge: .bottom)))
.animation(.easeOut(duration: 0.2).delay(Double(index) * 0.03), value: items)
```

### 7.3 Motion Principles

- **Purposeful**: Every animation communicates something — state change, spatial relationship, or feedback.
- **Fast by default**: Prefer 150–200ms. Users should never wait for animations.
- **Interruptible**: Use spring animations so transitions can be redirected mid-flight.
- **Reduce Motion**: Respect `@Environment(\.accessibilityReduceMotion)` — replace animations with instant state changes.
- **No bouncing**: Avoid playful bounce effects. Use critically damped or slightly underdamped springs only.

---

## 8. App States

### 8.1 Dashboard (Default State)

The default view is a **meeting dashboard** showing upcoming meetings grouped by day. Each meeting card offers two entry points: recording or notes-only.

```
┌─────────────────────────────────────────────────┐
│  Today · March 10, 2026                         │  ← heading2, text.primary
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │  ● 09:00  Sprint Planning        30m   │    │  ← status dot + heading3 + caption
│  │  with Sarah, Mike · Google Meet         │    │  ← footnote, text.secondary
│  │                                         │    │
│  │  [ ● Start Recording ]  [ ✎ Notes ]    │    │  ← primary btn + ghost btn
│  └─────────────────────────────────────────┘    │
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │  ○ 11:00  Product Sync           1 hr  │    │
│  │  with Design Team · Teams               │    │
│  │                                         │    │
│  │  [ ● Start Recording ]  [ ✎ Notes ]    │    │
│  └─────────────────────────────────────────┘    │
│                                                 │
│  Tomorrow · March 11, 2026                      │  ← heading3, text.secondary
│  ┌─────────────────────────────────────────┐    │
│  │  ○ 10:00  All Hands               1 hr │    │
│  │  ...                                    │    │
│  └─────────────────────────────────────────┘    │
│                                                 │
│  [ + Manual Meeting ]                           │  ← secondary btn, bottom-anchored
└─────────────────────────────────────────────────┘
```

**Meeting card styling**:
- Background: `background.tertiary`, border: 1pt `border.subtle`, radius: 8pt
- The next upcoming meeting is highlighted with `accent.primary` left border (3pt)
- Countdown timer on the next meeting: `.monospacedDigit()`, `text.tertiary`
- Past meetings (today, already ended) are dimmed (`text.tertiary`) with a "Review" button instead
- Meetings with existing notes show a small note indicator icon

**Two entry points per meeting**:
- **Start Recording** (primary button): enters full recording flow (audio capture + notes + transcription)
- **Notes** (ghost button): opens a lightweight notes editor — no audio, no transcription
  - Notes taken in notes-only mode are saved to SwiftData and exported to Obsidian
  - If recording is started later, existing notes carry over into the recording session
  - No summarization step for notes-only meetings (just raw notes export)

**Empty state** (no upcoming meetings at all):
- `ContentUnavailableView` with calendar icon, "No upcoming meetings" message
- "Start Manual Meeting" button
- Only shown when the calendar is truly empty for today and tomorrow

### 8.2 Notes-Only Mode

A lightweight editor for taking meeting notes without recording:

```
┌─────────────────────────────────────────────────┐
│  ← Back   Sprint Planning · 09:00              │  ← toolbar: heading3
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │                                         │    │
│  │  Type your notes here...                │    │  ← TextEditor, body, full height
│  │                                         │    │
│  │                                         │    │
│  │                                         │    │
│  │                                         │    │
│  └─────────────────────────────────────────┘    │
│                                                 │
│  [ ● Start Recording ]    [ Save & Export ]     │  ← Can upgrade to recording anytime
└─────────────────────────────────────────────────┘
```

- Auto-saves to SwiftData on every keystroke (debounced 500ms)
- "Start Recording" button allows upgrading to full recording mode at any time
- "Save & Export" writes notes to Obsidian vault as `{date} {subject} - Notes.md`
- Toolbar shows meeting title and time
- Markdown formatting support in the editor (bold, lists, headings)

### 8.3 Recording (Active Meeting)

This is the most critical state — it must be **unmistakable but not distracting**.

**Visual indicators**:
- Pulsing red dot in toolbar (8pt, `state.recording`)
- "REC" label + duration timer in toolbar
- Thin red line (2pt) along the top edge of the main content area
- Status bar (bottom): waveform visualization, subtle, `state.recording` color
- Window title suffix: " — Recording"
- App icon badge: recording indicator via `NSApp.dockTile`

**Audio waveform** (minimal, in status bar):
```swift
// Simplified waveform bars
HStack(spacing: 2) {
    ForEach(0..<5) { i in
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.stateRecording)
            .frame(width: 3, height: barHeights[i])
            .animation(.easeInOut(duration: 0.3), value: barHeights[i])
    }
}
.frame(height: 16)
```

### 8.4 Processing (Post-Meeting)

After recording ends, AI processes the transcript:

- State indicator changes: red dot becomes violet spinner
- Progress indication: indeterminate progress bar at top of content area, `accent.secondary` color
- Skeleton/shimmer loading placeholders where notes/summary will appear
- Status text: "Processing transcript..." → "Generating summary..." → "Identifying action items..."
- Use `.redacted(reason: .placeholder)` for shimmer effect on content shapes

### 8.5 Review (Meeting Complete)

- Full meeting detail view with rich content
- AI-generated sections clearly distinguished with `state.aiGenerated` background tint and `sparkles` icon
- Editable notes with inline editing
- Action items as interactive checkboxes
- Transcript with speaker labels, timestamps, and search/highlight capability

### 8.6 Error States

- Inline error banners: `accent.danger` at 10% bg, red left border (3pt), with message and retry action
- Toast notifications for transient errors: slide down from toolbar, auto-dismiss 4s
- Connection loss: yellow banner at top, "Reconnecting..." with spinner

---

## 9. Visual Hierarchy & Information Density

### 9.1 Hierarchy Levels

1. **Primary focus**: Meeting title, recording state, main transcript → `text.primary`, `heading2-3`
2. **Secondary context**: Participants, timestamps, metadata → `text.secondary`, `body/caption`
3. **Tertiary/ambient**: Dividers, backgrounds, empty placeholders → `text.tertiary`, minimal contrast
4. **Interactive/accent**: Buttons, links, active elements → `accent.primary`, clear affordance

### 9.2 Density Guidelines

- **Sidebar items**: 28pt row height, 8pt padding, no avatars in list (icon + text only)
- **Meeting list**: 72–80pt card height for compact list view, expandable for detail
- **Transcript lines**: 18pt line height, 4pt gap between speaker turns, 16pt gap between topics
- **Action items**: 28pt row height, checkbox + text + assignee avatar
- Use **disclosure groups** for progressive disclosure — don't show everything at once

### 9.3 Contrast & Readability

- Minimum 4.5:1 contrast ratio for body text in both modes
- Minimum 3:1 for large text and interactive elements
- AI-generated text uses `accent.secondary` to distinguish from user-written text (as Granola does with gray vs black)
- Timestamps and metadata can be lower contrast (`text.tertiary`) as they're supplementary

---

## 10. Keyboard Shortcuts & Navigation

Design the UI to surface keyboard shortcuts naturally:

| Action | Shortcut | Visual Hint |
|---|---|---|
| New meeting | `⌘N` | Menu + tooltip |
| Start/stop recording | `⌘R` | Toolbar button tooltip |
| Toggle sidebar | `⌘⇧S` | Toolbar button |
| Search | `⌘F` | Search field focus |
| Quick switch meeting | `⌘K` | Command palette (Raycast-style) |
| Settings | `⌘,` | Standard macOS |

### Command Palette (⌘K)

Inspired by Raycast/Linear — a floating search/command bar:
- Centered overlay, 480pt wide
- `.regularMaterial` background
- Corner radius: 12pt
- Large shadow for floating effect
- Search input at top (40pt height)
- Filtered results below with keyboard navigation
- Escape to dismiss, Enter to select

---

## 11. SwiftUI Implementation Notes

### 11.1 Design Token Implementation

```swift
// DesignTokens.swift
enum CasaSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

enum CasaRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 6
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
}

enum CasaDuration {
    static let micro: Double = 0.1
    static let fast: Double = 0.15
    static let standard: Double = 0.2
    static let emphasis: Double = 0.3
    static let slow: Double = 0.4
}
```

### 11.2 Color Asset Strategy

Define colors in an Asset Catalog with Light/Dark variants. Reference via:

```swift
extension Color {
    static let backgroundPrimary = Color("BackgroundPrimary")
    static let backgroundSecondary = Color("BackgroundSecondary")
    static let textPrimary = Color("TextPrimary")
    // ...
}
```

Alternatively, define programmatically for flexibility:

```swift
extension Color {
    static let backgroundPrimary = Color(
        light: Color(hex: "FFFFFF"),
        dark: Color(hex: "0D0D0F")
    )
}
```

### 11.3 Vibrancy & Materials

```swift
// Sidebar with native vibrancy
NavigationSplitView {
    SidebarContent()
        .background(.ultraThinMaterial)
} detail: {
    DetailContent()
}

// Floating panel
FloatingPanel()
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: CasaRadius.lg))
    .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
```

### 11.4 Reduce Motion Support

```swift
struct CasaAnimation {
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: CasaDuration.standard)
    }

    static func spring(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)
    }
}
```

### 11.5 Window Configuration

```swift
@main
struct CasablancaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))

        MenuBarExtra("Casablanca", systemImage: "mic.fill") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
```

---

## 12. Reference: Inspiration Mapping

| App | What to borrow |
|---|---|
| **Linear** | Information density, sidebar compactness, keyboard-first flow, minimal visual noise, three-variable theme system |
| **Raycast** | Command palette (⌘K), native macOS feel, speed, extension-style modularity |
| **Arc Browser** | Workspace concept (mapping to meeting contexts), smooth transitions, corner radius precision |
| **Notion Calendar** | Compact calendar integration, polished dark mode, event-centric navigation |
| **Granola** | Distinguishing AI text from user text (color differentiation), minimal UI during recording, notes-first approach |
| **Otter.ai** | Transcript layout with speaker labels, search within transcripts, real-time transcript streaming |
| **Loom** | Recording state UI, post-recording processing flow, share workflow |

---

## 13. Checklist: What Makes It Feel Premium

- [ ] Native macOS materials (vibrancy in sidebar, toolbar, popovers)
- [ ] SF Pro with proper weight hierarchy (no custom fonts needed)
- [ ] Consistent 4pt spacing grid throughout
- [ ] Spring-based animations, no linear or bouncy
- [ ] Keyboard shortcuts for every major action
- [ ] ⌘K command palette for power users
- [ ] Smooth sidebar collapse/expand
- [ ] Recording state is visible but calm (not alarming)
- [ ] AI content is clearly attributed but not visually jarring
- [ ] Empty states guide the user, not just show "nothing here"
- [ ] Staggered list animations on content load
- [ ] Respect system appearance (dark/light follows system, or manual override)
- [ ] Respect Reduce Motion accessibility setting
- [ ] Hover states on all interactive elements with fast transitions
- [ ] Focus rings on keyboard navigation
- [ ] Minimum 4.5:1 contrast ratio for text
- [ ] `.monospacedDigit()` on all live-updating numbers
- [ ] No layout shifts during state transitions
