#!/usr/bin/env bash

LAYOUT_DIR="${HOME}"
LAYOUT_DEFAULT="${LAYOUT_DIR}/.window-layout.txt"

layout_file() {
  local name="$1"
  if [[ -z "$name" ]]; then
    echo "$LAYOUT_DEFAULT"
  else
    echo "${LAYOUT_DIR}/.window-layout-${name}.txt"
  fi
}

list_layouts() {
  local files=("${LAYOUT_DIR}"/.window-layout*.txt)
  if [[ ! -e "${files[0]}" ]]; then
    echo "No saved layouts found."
    return
  fi
  echo "Saved layouts:"
  for f in "${files[@]}"; do
    local base
    base="$(basename "$f")"
    if [[ "$base" == ".window-layout.txt" ]]; then
      echo "  (default)   $f"
    else
      local name="${base#.window-layout-}"
      name="${name%.txt}"
      echo "  $name   $f"
    fi
  done
}

save_layout() {
  local LAYOUT_FILE="$1"
  if command -v swift &>/dev/null; then
    # Fast path: CGWindowListCopyWindowInfo returns all windows in one shot (~0.5s).
    # executableURL.lastPathComponent gives the process name that matches
    # System Events (e.g. "Notes" not "Notizen" on a German system).
    # kCGWindowName requires Screen Recording permission; saved as empty if not granted.
    swift - 2>/dev/null <<'SWIFT' > "$LAYOUT_FILE"
import CoreGraphics
import AppKit

let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
guard let windowList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(0) }

var lines: [String] = []
for win in windowList {
    guard let pid     = win[kCGWindowOwnerPID as String] as? Int32,
          let layer   = win[kCGWindowLayer    as String] as? Int32, layer == 0,
          let rawRect = win[kCGWindowBounds   as String] else { continue }

    guard let app = NSRunningApplication(processIdentifier: pid),
          app.activationPolicy == .regular,
          let appName = app.executableURL?.lastPathComponent, !appName.isEmpty else { continue }

    var bounds = CGRect.zero
    CGRectMakeWithDictionaryRepresentation(rawRect as! CFDictionary, &bounds)
    let width = Int(bounds.width), height = Int(bounds.height)
    guard width >= 100 && height >= 50 else { continue }

    let title = win[kCGWindowName as String] as? String ?? ""
    let x = Int(bounds.origin.x), y = Int(bounds.origin.y)
    lines.append("\(appName)\t\(title)\t\(x)\t\(y)\t\(width)\t\(height)")
}
print(lines.joined(separator: "\n"))
SWIFT
  else
    # Fallback when Swift/Xcode CLT is not installed (~10s)
    osascript <<'APPLESCRIPT' > "$LAYOUT_FILE"
tell application "System Events"
  set layoutLines to {}
  repeat with p in (every process whose background only is false)
    set appName to name of p
    try
      repeat with w in windows of p
        try
          set wName to ""
          try
            set wName to name of w
          end try
          set {x, y} to position of w
          set {wWidth, wHeight} to size of w
          set end of layoutLines to appName & tab & wName & tab & x & tab & y & tab & wWidth & tab & wHeight
        end try
      end repeat
    end try
  end repeat
end tell
set AppleScript's text item delimiters to linefeed
return layoutLines as text
APPLESCRIPT
  fi
}

restore_layout() {
  local LAYOUT_FILE="$1"
  if [[ ! -f "$LAYOUT_FILE" ]]; then
    echo "No layout file at $LAYOUT_FILE" >&2
    exit 1
  fi

  # NOTE: here we embed the path directly in the AppleScript; we do NOT
  # pass the file as an argument to osascript (that caused your error).
  osascript <<APPLESCRIPT
set layoutPath to POSIX file "${LAYOUT_FILE}"

set theData to ""
try
  set theData to read layoutPath
on error
  return
end try

if theData is "" then return

set AppleScript's text item delimiters to linefeed
set theLines to paragraphs of theData

-- Per-app window counters for index-based fallback when title doesn't match
set trackedApps to {}
set trackedCounts to {}

tell application "System Events"
  repeat with ln in theLines
    if ln is not "" then
      set AppleScript's text item delimiters to tab
      set itemsList to text items of ln
      -- Accept 6 or 7 fields (save script sometimes appends an extra field)
      if (count of itemsList) >= 6 then
        set appName to item 1 of itemsList
        set winTitle to item 2 of itemsList
        set x to (item 3 of itemsList) as integer
        set y to (item 4 of itemsList) as integer
        set wWidth to (item 5 of itemsList) as integer
        set wHeight to (item 6 of itemsList) as integer

        -- Track per-app window index for fallback matching
        set appIdx to 0
        repeat with i from 1 to count of trackedApps
          if item i of trackedApps = appName then
            set appIdx to i
            exit repeat
          end if
        end repeat
        if appIdx = 0 then
          set end of trackedApps to appName
          set end of trackedCounts to 0
          set appIdx to count of trackedApps
        end if
        set fallbackIdx to (item appIdx of trackedCounts) + 1
        set item appIdx of trackedCounts to fallbackIdx

        -- Make sure app is running; if not, try to launch it
        try
          if not (exists process appName) then
            tell application appName to launch
            delay 1
          end if
        end try

        if exists process appName then
          set p to first process whose name is appName
          try
            set ws to windows of p
            set matchedWindow to missing value

            -- First pass: exact title match
            repeat with w in ws
              try
                set currentTitle to ""
                try
                  set currentTitle to name of w
                end try
                if winTitle is not "" and currentTitle = winTitle then
                  set matchedWindow to w
                  exit repeat
                end if
              end try
            end repeat

            -- Fallback: match by position index (handles apps with dynamic titles like Terminal)
            if matchedWindow is missing value then
              if fallbackIdx <= (count of ws) then
                set matchedWindow to item fallbackIdx of ws
              else if (count of ws) > 0 then
                set matchedWindow to item (count of ws) of ws
              end if
            end if

            if matchedWindow is not missing value then
              try
                if (exists attribute "AXMinimized" of matchedWindow) then
                  if value of attribute "AXMinimized" of matchedWindow is true then
                    set value of attribute "AXMinimized" of matchedWindow to false
                  end if
                end if
              end try
              try
                set position of matchedWindow to {x, y}
                set size of matchedWindow to {wWidth, wHeight}
              end try
            end if
          end try
        end if
      end if
    end if
  end repeat
end tell
APPLESCRIPT
}

case "$1" in
  -r|--restore|-restore)
    f="$(layout_file "$2")"
    restore_layout "$f"
    ;;
  -s|--save|-save)
    f="$(layout_file "$2")"
    save_layout "$f"
    echo "Layout saved to $f"
    ;;
  -l|--list|-list)
    list_layouts
    ;;
  *)
    echo "Usage: $(basename "$0") -s|--save   [name]   Save current window layout"
    echo "       $(basename "$0") -r|--restore [name]   Restore saved window layout"
    echo "       $(basename "$0") -l|--list             List all saved layouts"
    echo ""
    echo "  name  Optional. Saves/restores ~/.window-layout-<name>.txt"
    echo "        Omit to use the default layout (~/.window-layout.txt)"
    exit 0
    ;;
esac