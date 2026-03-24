//===============================================================================
// Orchestrator - Quickly orchestrate sketches in MuseScore Studio
//
// Copyright (C) 2026 Eric Warren (eakwarren)
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License version 3
// as published by the Free Software Foundation and appearing in
// the file LICENSE
//===============================================================================

import QtQuick 2.15
import QtQuick.Controls 2.15
// import QtQuick.Dialogs
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import Muse.Ui
import Muse.UiComponents
import MuseScore 3.0

pragma Singleton

MuseScore {
    id: root

    categoryCode: "Composing/arranging tools"
    description: qsTr("Quickly orchestrate sketches")
    thumbnailName: "orchestrator.png"
    title: qsTr("Orchestrator")
    version: "0.1.1"


    // Sprint 1: window base width and settings panel animation
    property int baseWidth: 300
    property bool settingsOpen: false
    property bool gridView: false
    property var orchestratorWin: null // runtime-created Window instance

    // ---- Sprint 1: Staves list state (ported from Keyswitch Creator) ----
    // Current multi-select state (staff index -> true)
    property var selectedStaff: ({})
    property int selectedCountProp: 0
    property int lastAnchorIndex: -1
    property int currentStaffIdx: -1
    property bool liveCommitEnabled: true

    // Theme convenience
    readonly property color themeAccent: ui.theme.accentColor
    property color pluginAccent: (ocPrefs.accentHex && ocPrefs.accentHex.length) ? ocPrefs.accentHex : ui.theme.accentColor
    // Put near the top level of your plugin
    property bool isDarkTheme: (function () {
        if (ui && ui.theme && ui.theme.isDark !== undefined) {
            const v = ui.theme.isDark
            return (typeof v === "function") ? !!v() : !!v
        }
        // Fallback: classify by luminance of the background color
        // var c = ui && ui.theme ? ui.theme.backgroundPrimaryColor : "black"
        // function lin(x) { return (x <= 0.04045) ? (x / 12.92) : Math.pow((x + 0.055) / 1.055, 2.4) }
        // var r = lin(c.r || 0), g = lin(c.g || 0), b = lin(c.b || 0)
        // var Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        // return Y < 0.5
    })

    // ---- Orchestrator Presets: persistence + helpers (modeled after KSC) ------------------
    // Store presets JSON via QML Settings (on-disk per-user config)
    Settings {
        id: ocPrefs
        category: "Orchestrator"
        // Single string holds our presets array as JSON
        property string presetsJSON: ""
        property string accentHex: ""

        property bool lastSettingsOpen: false
        property int  lastWindowHeight: 0
        property bool lastGridView: false
        property int  lastSelectedIndex: -1
        property int  lastWindowX: 0
        property int  lastWindowY: 0
    }

    // In-memory presets array
    // Schema: [{ id, name, staves:[int...], rows:[{active:bool, voice:1..4, offset:-24..24} x8] }, ...]
    property var presets: ([])
    property bool suppressApplyPreset: false
    property bool creatingNewPreset: false

    // Persist Settings panel open/closed
    onSettingsOpenChanged: {
        try {
            ocPrefs.lastSettingsOpen = settingsOpen;
            if (ocPrefs.sync) ocPrefs.sync();
        } catch (e) {}
    }

    // Persist 1-up vs 2-up layout
    onGridViewChanged: {
        try {
            ocPrefs.lastGridView = !!gridView;
            if (ocPrefs.sync) ocPrefs.sync();
        } catch (e) {}
    }

    // Keys controlled by the "All" checkbox (exclude the 'all' key itself)
    readonly property var notationFilterKeys: [
        "dynamics","hairpins","fingerings","lyrics","chordSymbols","otherText",
        "articulations","ornaments","slurs","ties","figuredBass","ottavas",
        "pedalLines","otherLines","arpeggios","glissandos","fretboardDiagrams",
        "breathMarks","tremolos","graceNotes"
    ]

    // Return 0/1/2 for Unchecked / PartiallyChecked / Checked
    function notationAllState(nf) {
        if (!nf) return 0
        var total = notationFilterKeys.length
        var enabled = 0
        for (var i = 0; i < total; ++i) if (nf[notationFilterKeys[i]]) enabled++
        if (enabled === 0) return Qt.Unchecked
        if (enabled === total) return Qt.Checked
        return Qt.PartiallyChecked
    }

    // Set all children on/off and keep nf.all in sync
    function setNotationAll(nf, on) {
        if (!nf) return
        for (var i = 0; i < notationFilterKeys.length; ++i)
            nf[notationFilterKeys[i]] = !!on
        nf.all = !!on
    }

    // Recompute nf.all from children
    function syncNotationAll(nf) {
        if (!nf) return
        var st = notationAllState(nf)
        nf.all = (st === Qt.Checked)
    }

    // Pitch offset <-> dropdown index mapping (0..48, where 24 == 0 semitones)
    function pitchValueToIndex(v) {
        var n = Number(v) || 0
        if (n > 24) n = 24
        if (n < -24) n = -24
        if (n > 0) return 24 - n
        if (n === 0) return 24
        return 24 + (-n)
    }
    function pitchIndexToValue(ix) {
        var i = Number(ix) || 24
        if (i < 0) i = 0
        if (i > 48) i = 48
        if (i < 24) return 24 - i
        if (i === 24) return 0
        return -(i - 24)
    }

    function defaultRows() {
        var rows = []
        for (var i = 0; i < 8; ++i)
            rows.push({ active: false, offset: 0, voice: 1 })
        return rows
    }

    // Default notation elements filter (all enabled by default)
    function defaultNotationFilter() {
        return {
            all: true,
            dynamics: true,
            hairpins: true,
            fingerings: true,
            lyrics: true,
            chordSymbols: true,   // Harmony
            otherText: true,      // Staff/System/Tempo text, etc.
            articulations: true,  // incl. fermatas
            ornaments: true,
            slurs: true,
            ties: true,
            figuredBass: true,
            ottavas: true,
            pedalLines: true,
            otherLines: true,     // generic text lines / voltas etc. (subject to later scoping)
            arpeggios: true,
            glissandos: true,
            fretboardDiagrams: true,
            breathMarks: true,
            tremolos: true,
            graceNotes: true
        }
    }

    function newPresetObject(name) {
        return {
            id: String(Date.now()) + "_" + Math.floor(Math.random() * 100000),
            name: String(name ?? qsTr("New Preset")),
            staves: [],
            noteRowsByStaff: {},
            backgroundColor: "",
            notationFilter: defaultNotationFilter()
        }
    }

    // Selected staff indices (sorted) from the left staves list
    function getSelectedStaffArray() {
        var out = []
        for (var k in selectedStaff) {
            if (selectedStaff.hasOwnProperty(k) && selectedStaff[k]) out.push(Number(k))
        }
        out.sort(function(a,b){return a-b})
        return out
    }
    function setSelectedStaffFromArray(arr) {
        clearSelection()
        if (!arr || !arr.length) return
        for (var r = 0; r < staffListModel.count; ++r) {
            var sIdx = staffListModel.get(r).idx
            if (arr.indexOf(sIdx) >= 0) setRowSelected(r, true)
        }
        var sl = orchestratorWin ? orchestratorWin.staffListRef : null
        if (sl) {
            for (var r2 = 0; r2 < staffListModel.count; ++r2) {
                if (isRowSelected(r2)) { sl.currentIndex = r2; break; }
            }
        }
    }
    function staffNamesFromIndices(arr) {
        if (!arr || !arr.length) return ""
        var names = []
        for (var i = 0; i < arr.length; ++i) names.push(staffNameByIdx(arr[i]))
        return names.join(", ")
    }

    // Serialize / deserialize the in-memory presets
    function loadPresetsFromSettings() {
        try {
            var s = String(ocPrefs.presetsJSON || "")
            var parsed = s.length ? JSON.parse(s) : []
            if (!parsed || !parsed.length) parsed = [ newPresetObject(qsTr("New Preset")) ]
            presets = parsed
            // --- Inject notationFilter defaults for older presets ---
            for (var i = 0; i < presets.length; ++i) {
                var p = presets[i];
                if (!p.notationFilter) {
                    p.notationFilter = newPresetObject().notationFilter;
                } else {
                    // ensure all keys exist
                    var defaults = newPresetObject().notationFilter;
                    for (var k in defaults) {
                        if (!p.notationFilter.hasOwnProperty(k))
                            p.notationFilter[k] = defaults[k];
                    }
                }
            }
        } catch (e) {
            presets = [ newPresetObject(qsTr("New Preset")) ]
        }
        refreshPresetsListModel()
    }
    function savePresetsToSettings() {
        try {
            ocPrefs.presetsJSON = JSON.stringify(presets, null, 2)
            if (ocPrefs.sync) { try { ocPrefs.sync() } catch (e2) {} }
        } catch (e) {
            console.log("[Orchestrator] Failed to save presets:", String(e))
        }
    }

    function notifyPresetsMutated() {
        // Reassign to a fresh array reference so QML bindings re-evaluate.
        presets = presets.slice(0);
    }

    // Returns true if any row has active === true
    function hasAnyActiveRows(rows) {
        if (!rows || !rows.length) return false;
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i] && rows[i].active) return true;
        }
        return false;
    }

    // --- Clipboard + helpers ----------------------------------------------------

    // Holds a snapshot of a preset's assignments:
    // { staves: [int...], noteRowsByStaff: { [sid]: [{active, offset, voice} x 8] } }
    property var presetClipboard: null

    function __deepCloneRowsArray(rows) {
        var out = [];
        for (var i = 0; i < 8; ++i) {
            var r = (rows && rows[i]) ? rows[i] : { active: false, offset: 0, voice: 1 };
            out.push({
                         active: !!r.active,
                         offset: Number(r.offset || 0),
                         voice: Number(r.voice || 1)
                     });
        }
        return out;
    }

    function __staffIdsWithAnyActive(p) {
        var ids = [];
        if (!p || !p.noteRowsByStaff) return ids;
        for (var sid in p.noteRowsByStaff) {
            if (!p.noteRowsByStaff.hasOwnProperty(sid)) continue;
            var rows = p.noteRowsByStaff[sid] || [];
            if (hasAnyActiveRows(rows)) ids.push(Number(sid));
        }
        ids.sort(function(a, b) { return a - b; });
        return ids;
    }

    function __presetIsEmpty(p) {
        return __staffIdsWithAnyActive(p).length === 0;
    }

    function canCopyCurrentPreset() {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
            return false;
        var p = presets[uiRef.selectedIndex];
        return !__presetIsEmpty(p);
    }

    function canPasteIntoCurrentPreset() {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!presetClipboard || !uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
            return false;
        var p = presets[uiRef.selectedIndex];
        return __presetIsEmpty(p);
    }

    function copyCurrentPresetToClipboard() {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
            return;

        var p = presets[uiRef.selectedIndex];
        if (!p || !p.noteRowsByStaff) return;

        var clip = { staves: [], noteRowsByStaff: {} };
        clip.name = String(p.name || "");
        clip.backgroundColor = p.backgroundColor ? colorToHex(p.backgroundColor) : "";

        clip.notationFilter = p.notationFilter ? JSON.parse(JSON.stringify(p.notationFilter)) : defaultNotationFilter();

        // Only copy staves that actually have any active rows
        var ids = __staffIdsWithAnyActive(p);
        clip.staves = ids.slice(0);

        for (var i = 0; i < ids.length; ++i) {
            var sid = ids[i];
            clip.noteRowsByStaff[sid] = __deepCloneRowsArray(p.noteRowsByStaff[sid]);
        }
        presetClipboard = clip;
    }

    function pasteClipboardIntoCurrentPreset() {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!presetClipboard || !uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
            return;

        var p = presets[uiRef.selectedIndex];
        if (!p) return;
        if (!__presetIsEmpty(p)) {
            // Guard: only allow paste into an empty preset
            return;
        }
        if (!p.noteRowsByStaff) p.noteRowsByStaff = {};

        // Apply clipboard to the preset (deep clone)
        p.staves = presetClipboard.staves ? presetClipboard.staves.slice(0) : [];
        if (presetClipboard.noteRowsByStaff) {
            for (var sidKey in presetClipboard.noteRowsByStaff) {
                if (!presetClipboard.noteRowsByStaff.hasOwnProperty(sidKey)) continue;
                var srcRows = presetClipboard.noteRowsByStaff[sidKey] || [];
                p.noteRowsByStaff[sidKey] = __deepCloneRowsArray(srcRows);
            }
        }

        // Rename the target preset to "<source name> copy"
        var baseName = (presetClipboard && typeof presetClipboard.name === 'string' && presetClipboard.name.length)
                ? presetClipboard.name
                : qsTr("New Preset");
        p.name = baseName + " copy";

        // Restore backgroundColor (if any)
        if (presetClipboard.backgroundColor && presetClipboard.backgroundColor.length) {
            p.backgroundColor = presetClipboard.backgroundColor;   // hex → parsed automatically
        } else {
            try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
        }

        // Restore notationFilter (if present)
        if (presetClipboard.notationFilter) {
            p.notationFilter = JSON.parse(JSON.stringify(presetClipboard.notationFilter));
        } else {
            p.notationFilter = defaultNotationFilter();
        }

        // Reflect the new name in the title field immediately
        var tf = orchestratorWin ? orchestratorWin.presetTitleFieldRef : null;
        if (tf) {
            tf.text = p.name;
            tf.cursorPosition = 0;
            tf.deselect();
        }

        // Keep derived data consistent and refresh
        notifyPresetsMutated();
        refreshPresetsListModel();
        savePresetsToSettings();
    }

    function colorToHex(c) {
        if (!c) return "";
        var r = Math.round(c.r * 255);
        var g = Math.round(c.g * 255);
        var b = Math.round(c.b * 255);
        var a = Math.round(c.a * 255);

        function hex(v) {
            var h = v.toString(16);
            return h.length === 1 ? "0" + h : h;
        }

        return (a < 255)
                ? "#" + hex(a) + hex(r) + hex(g) + hex(b)   // ARGB form
                : "#" + hex(r) + hex(g) + hex(b);          // RGB form
    }

    // Instrument-only name (no ": Staff N") for use on the preset card
    function staffInstrumentNameByIdx(staffIdx) {
        var p = partForStaff(staffIdx);
        var nm = nameForPart(p, 0) || 'Unknown instrument';
        return cleanName(nm);
    }

    // Join instrument names for the preset card (no ": Staff N")
    function staffInstrumentNamesFromIndices(arr) {
        if (!arr || !arr.length) return "";
        var names = [];
        for (var i = 0; i < arr.length; ++i) {
            names.push(staffInstrumentNameByIdx(arr[i]));
        }
        return names.join(", ");
    }

    // Rebuild the visible cards list from `presets`
    function refreshPresetsListModel() {
        var model = orchestratorWin ? orchestratorWin.allPresetsModelRef : null
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null
        if (!model) return

        model.clear()
        for (var i = 0; i < presets.length; ++i) {
            var p = presets[i]
            model.append({
                             name: String(p.name || qsTr("New Preset")),
                             count: (function () {
                                 // Count UNIQUE active row indices (0..7) across ALL staves
                                 // that have data in noteRowsByStaff (not just p.staves)
                                 var seen = {};
                                 if (p && p.noteRowsByStaff) {
                                     for (var sid in p.noteRowsByStaff) {
                                         if (!p.noteRowsByStaff.hasOwnProperty(sid))
                                             continue;
                                         var rows = p.noteRowsByStaff[sid] || [];
                                         for (var i = 0; i < rows.length && i < 8; ++i) {
                                             if (rows[i] && rows[i].active)
                                                 seen[i] = true;
                                         }
                                     }
                                 }
                                 var c = 0;
                                 for (var k in seen)
                                     if (seen.hasOwnProperty(k)) c++;
                                 return c;
                             })(),

                             staves: (function () {
                                 // Display all staves that actually have *active* notes (instrument-only names)
                                 if (!p || !p.noteRowsByStaff)
                                     return "";
                                 var ids = [];
                                 for (var sid in p.noteRowsByStaff) {
                                     if (!p.noteRowsByStaff.hasOwnProperty(sid))
                                         continue;
                                     var rows = p.noteRowsByStaff[sid] || [];
                                     if (hasAnyActiveRows(rows))
                                         ids.push(Number(sid));
                                 }
                                 ids.sort(function(a,b){ return a-b; });
                                 return staffInstrumentNamesFromIndices(ids);
                             })(),
                         })
        }
        // Do NOT auto-select the first card unless settings panel is open,
        // and there is no previously-stored selection to restore.
        if (model.count > 0 && uiRef && uiRef.selectedIndex < 0 && root.settingsOpen) {
            var storedSel = (ocPrefs && typeof ocPrefs.lastSelectedIndex === "number") ? ocPrefs.lastSelectedIndex : -1;
            if (!(storedSel >= 0)) {
                uiRef.selectedIndex = 0;
            }
        }
    }

    // Push UI state -> presets[selected]
    function updatePresetFromUI(index) {
        if (index < 0 || index >= presets.length) return
        var p = presets[index]
        var tf = orchestratorWin ? orchestratorWin.presetTitleFieldRef : null
        var nb = orchestratorWin ? orchestratorWin.noteButtonsPaneRef : null

        // title
        p.name = String((tf && tf.text !== undefined) ? tf.text : p.name)

        // --- IMPORTANT FIX: Never modify staves if no staff is currently focused ---
        var currentSid = -1;
        if (orchestratorWin && orchestratorWin.staffListRef && orchestratorWin.staffListRef.currentIndex >= 0)
            currentSid = staffListModel.get(orchestratorWin.staffListRef.currentIndex).idx;

        // If no staff in the preset is focused, do NOT recompute p.staves.
        // Prevents deleting the first staff when Save is pressed with no selection.
        if (currentSid < 0) {
            return;
        }

        // staves: include only those with at least one active note (assignment != selection)
        if (p.noteRowsByStaff) {
            var ids = [];
            for (var sIdKey in p.noteRowsByStaff) {
                if (!p.noteRowsByStaff.hasOwnProperty(sIdKey))
                    continue;
                var rows0 = p.noteRowsByStaff[sIdKey] || [];
                if (hasAnyActiveRows(rows0))
                    ids.push(Number(sIdKey));
            }
            ids.sort(function(a,b){ return a-b; });
            p.staves = ids;
        } else {
            p.staves = [];
        }

        // per-staff note row storage — update ONLY the currently-focused staff
        if (!p.noteRowsByStaff)
            p.noteRowsByStaff = {};

        var sid = -1;
        if (orchestratorWin && orchestratorWin.staffListRef && orchestratorWin.staffListRef.currentIndex >= 0)
            sid = staffListModel.get(orchestratorWin.staffListRef.currentIndex).idx;
        else if (p.staves && p.staves.length > 0)
            sid = p.staves[0]; // fallback

        if (sid >= 0) {
            var rows = [];
            for (var i = 0; i < 8; ++i) {
                var active  = nb ? !!nb.selectedNotes[i] : false;
                var voice   = Number(nb && nb.voiceByRow ? (nb.voiceByRow[i] ?? 1) : 1);
                var pitchIx = (nb && nb.pitchIndexByRow && nb.pitchIndexByRow[i] !== undefined) ? nb.pitchIndexByRow[i] : 24;
                var offset  = pitchIndexToValue(pitchIx);
                rows.push({ active: active, offset: offset, voice: voice });
            }
            p.noteRowsByStaff[sid] = rows;
        }
    }

    // Gather the 8 rows from the current Note Buttons UI (selected, voice, offset)
    function collectRowsFromNoteButtons() {
        var nb = orchestratorWin ? orchestratorWin.noteButtonsPaneRef : null;
        var rows = [];
        for (var i = 0; i < 8; ++i) {
            var active  = nb ? !!nb.selectedNotes[i] : false;
            var voice   = Number(nb && nb.voiceByRow ? (nb.voiceByRow[i] ?? 1) : 1);
            var pitchIx = (nb && nb.pitchIndexByRow && nb.pitchIndexByRow[i] !== undefined) ? nb.pitchIndexByRow[i] : 24;
            var offset  = pitchIndexToValue(pitchIx);
            rows.push({ active: active, offset: offset, voice: voice });
        }
        return rows;
    }

    // Fully reset the 8-row note-buttons UI without letting any live commit fire.
    function resetNoteButtonsUI() {
        var nb = orchestratorWin ? orchestratorWin.noteButtonsPaneRef : null;
        if (!nb) return;

        var prevCommit = root.liveCommitEnabled;
        root.liveCommitEnabled = false;   // block any scheduled commits while resetting

        try {
            // 1) Clear selection flags
            nb.selectedNotes = ({});

            // 2) Reset voices: default each row to voice 1
            var vb = {};
            for (var i = 0; i < 8; ++i) vb[i] = 1;
            nb.voiceByRow = vb;

            // 3) Reset pitch indices to center (24 == 0 semitones)
            var pi = {};
            for (var j = 0; j < 8; ++j) pi[j] = 24;
            nb.pitchIndexByRow = pi;
        } finally {
            root.liveCommitEnabled = prevCommit;   // restore previous policy
        }
    }

    // Commit current UI rows to the *current preset* for all *selected staves*
    // (or the focused staff if none are selected). Then notify and refresh the cards.
    function commitNoteRowsToPresetLive() {
        // New guards: never commit while a new preset is being created, or when live commits are disabled
        if (root.creatingNewPreset || !root.liveCommitEnabled)
            return;

        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
            return;

        var p = presets[uiRef.selectedIndex];
        if (!p) return;
        if (!p.noteRowsByStaff) p.noteRowsByStaff = {};

        // Targets: all selected staves; if none, use the focused/first staff
        var keys = Object.keys(selectedStaff || {});
        var targetIds = [];

        if (keys.length > 0) {
            for (var k = 0; k < keys.length; ++k) {
                var sidNum = parseInt(keys[k], 10);
                if (!isNaN(sidNum)) targetIds.push(sidNum);
            }
        } else {
            var sid = -1;
            if (orchestratorWin && orchestratorWin.staffListRef && orchestratorWin.staffListRef.currentIndex >= 0)
                sid = staffListModel.get(orchestratorWin.staffListRef.currentIndex).idx;
            // No selected staves and no current focus: do not commit.
            if (sid >= 0) targetIds.push(sid);
            else return;
        }

        var rows = collectRowsFromNoteButtons();
        // Deep copy into each target staff (avoid sharing the same array instance)
        // Deep copy into each target staff (or remove if no active rows)
        for (var t = 0; t < targetIds.length; ++t) {
            var sId = targetIds[t];
            if (hasAnyActiveRows(rows)) {
                var cloned = [];
                for (var i = 0; i < rows.length; ++i)
                    cloned.push({ active: rows[i].active, offset: rows[i].offset, voice: rows[i].voice });
                p.noteRowsByStaff[sId] = cloned;
            } else {
                // No active rows -> remove assignment for this staff
                try { delete p.noteRowsByStaff[sId]; } catch (e) {}
            }
        }

        // Nudge QML bindings so accent bars and other bindings react immediately
        notifyPresetsMutated();

        // Update the cards list *count* now (preserve current selection)
        var keep = uiRef.selectedIndex;
        refreshPresetsListModel();
        if (orchestratorWin && orchestratorWin.allPresetsModelRef)
            uiRef.selectedIndex = Math.min(keep, Math.max(0, orchestratorWin.allPresetsModelRef.count - 1));
    }

    // Coalesce multiple UI events into a single commit on the next tick
    function scheduleLiveCommit() {
        if (!root.liveCommitEnabled)
            return;
        Qt.callLater(function () { commitNoteRowsToPresetLive(); });
    }

    // Pull presets[selected] -> UI
    function applyPresetToUI(index, opts) {
        if (index < 0 || index >= presets.length) return
        var p = presets[index]
        var tf = orchestratorWin ? orchestratorWin.presetTitleFieldRef : null
        var nb = orchestratorWin ? orchestratorWin.noteButtonsPaneRef : null

        // Update title and default caret/cursor to the beginning
        if (tf) {
            tf.text = p.name ?? qsTr("New Preset")
            tf.cursorPosition = 0
            tf.deselect()
        }

        // When switching presets, we do want to rebuild the staff selection from the preset.
        // Start with no staff selected unless the caller asked to preserve
        var preserve = !!(opts && opts.preserveStaffSelection)
        if (!preserve) {
            clearSelection()
            var sl = orchestratorWin ? orchestratorWin.staffListRef : null
            if (sl) sl.currentIndex = -1
        }

        if (!nb) return // window not ready yet; bail out cleanly

        // Suppress live commits while populating the UI with preset data
        var _prevCommit = root.liveCommitEnabled;
        root.liveCommitEnabled = false;
        try {
            // Load only if a staff is actually selected/focused; otherwise keep UI empty
            nb.clearNoteSelection();

            var sid = -1;
            if (orchestratorWin && orchestratorWin.staffListRef && orchestratorWin.staffListRef.currentIndex >= 0)
                sid = staffListModel.get(orchestratorWin.staffListRef.currentIndex).idx;

            // Nothing selected -> leave note UI empty and return (pane is hidden by binding anyway)
            if (sid < 0)
                return;

            var rowsForStaff = (p.noteRowsByStaff && p.noteRowsByStaff[sid]) ? p.noteRowsByStaff[sid] : defaultRows();

            var vb = {}, pi = {};
            for (var i = 0; i < 8; ++i) {
                var row = rowsForStaff[i] ?? { active:false, offset:0, voice:1 };
                if (row.active) nb.setNoteSelected(i, true)
                vb[i] = (row.voice >= 1 && row.voice <= 4) ? row.voice : 1
                pi[i] = pitchValueToIndex(row.offset ?? 0)
            }
            nb.voiceByRow = vb
            nb.pitchIndexByRow = pi
        } finally {
            // Re-enable live commits for subsequent user edits
            root.liveCommitEnabled = _prevCommit;
        }
    }

    // Centralized delete logic (source of truth = presets[])
    function deletePresetAtIndex(idx) {
        if (idx < 0 || idx >= presets.length)
            return;

        // Mutate data
        presets.splice(idx, 1);

        // Keep bindings/reactivity and persistence in sync
        notifyPresetsMutated();
        savePresetsToSettings();
        refreshPresetsListModel();

        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        var tf   = orchestratorWin ? orchestratorWin.presetTitleFieldRef : null;
        if (uiRef) {
            var newSel = (presets.length > 0) ? Math.min(idx, presets.length - 1) : -1;

            // --- NEW: update the title immediately (authoritative) ---
            if (tf) {
                if (newSel >= 0 && newSel < presets.length) {
                    tf.text = String(presets[newSel].name || qsTr("New Preset"));
                } else {
                    tf.text = qsTr("New Preset");
                }
                tf.cursorPosition = 0;
                tf.deselect();
            }

            // Keep the rest of the UI in sync via a real selection transition
            uiRef.selectedIndex = -1;
            if (newSel >= 0) {
                Qt.callLater(function () { uiRef.selectedIndex = newSel; });
            }
        }
    }

    function saveCurrentPreset() {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null
        var model = orchestratorWin ? orchestratorWin.allPresetsModelRef : null
        var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1

        if (sel < 0 && presets.length === 0) presets.push(newPresetObject(qsTr("New Preset")))
        if (sel < 0) sel = 0

        updatePresetFromUI(sel)
        notifyPresetsMutated()
        savePresetsToSettings()

        var keep = uiRef ? uiRef.selectedIndex : -1
        refreshPresetsListModel()
        if (uiRef && model)
            uiRef.selectedIndex = Math.min(keep, Math.max(0, model.count - 1))
    }

    // --- Orchestrate: helpers + engine (selection -> target staves) ---

    // Clamp integer with bounds
    function clampInt(v, lo, hi) {
        var n = parseInt(v, 10)
        if (isNaN(n)) return lo
        return Math.max(lo, Math.min(hi, n))
    }

    // Ensure a writable slot at the cursor's current fraction by creating a rest, then restore position.
    // (Same write-safety pattern used in Keyswitch Creator)  // see ensureWritableSlot() usage there
    function ensureWritableSlot(c, num, den) {
        var t = c.fraction
        c.setDuration(num, den)
        try { c.addRest() } catch (e) {}
        c.rewindToFraction(t)
    } // [1](https://stlukes-my.sharepoint.com/personal/ewarren_slhs_org/Documents/Microsoft%20Copilot%20Chat%20Files/keyswitch_creator.txt)

    // Extract ascending pitches from a CHORD element (returns array of ints, low -> high)
    function chordPitchesAsc(ch) {
        var arr = []
        try {
            if (ch && ch.type === Element.CHORD && ch.notes) {
                for (var i in ch.notes) {
                    var n = ch.notes[i]
                    if (n && n.pitch !== undefined)
                        arr.push(parseInt(n.pitch, 10))
                }
            }
        } catch (e) {}
        arr.sort(function(a, b){ return a - b })
        return arr
    }

    // Returns the source pitch for the given row index in the 8-row UI.
    // Row labels (top..bottom):
    // 0: Top, 1: Seventh, 2: Sixth, 3: Fifth, 4: Fourth, 5: Third, 6: Second, 7: Bottom
    // Mapping rules:
    // - Top (0)    -> topmost note (index n-1)
    // - Bottom (7) -> bottommost note (index 0)
    // - Others     -> kth-from-bottom (k = 7 - rowIndex), clamped to existing range
    function pitchForRowFromChord(ch, rowIndex) {
        var asc = chordPitchesAsc(ch)
        if (!asc.length) return null
        var n = asc.length
        var idx

        if (rowIndex === 0) {
            // Top
            idx = n - 1
        } else if (rowIndex === 7) {
            // Bottom
            idx = 0
        } else {
            // 1..6 map to 2nd..7th from bottom; clamp to top if chord is smaller
            var fromBottom = 7 - rowIndex   // row 6 -> 1 (Second), row 1 -> 6 (Seventh)
            idx = Math.min(fromBottom, n - 1)
        }

        return asc[idx]
    }

    // Collect normal-note CHORDs on a specific source staff inside current selection window
    function collectSourceChordsInSelectionForStaff(srcStaffIdx) {
        var chords = []
        if (!curScore || !curScore.selection) return chords

        if (curScore.selection.isRange) {
            var startTick = curScore.selection.startSegment.tick
            var endTick = curScore.selection.endSegment ? curScore.selection.endSegment.tick : (curScore.lastSegment ? curScore.lastSegment.tick + 1 : startTick)
            var c = curScore.newCursor()
            c.track = srcStaffIdx * 4
            c.rewindToTick(startTick)
            while (c.segment && c.tick < endTick) {
                var el = c.element
                if (el && el.type === Element.CHORD && el.noteType === NoteType.NORMAL)
                    chords.push(el)
                if (!c.next()) break
            }
        } else {
            // list selection: filter to the same staff as the first chord/note
            for (var i = 0; i < curScore.selection.elements.length; ++i) {
                var el = curScore.selection.elements[i]
                var ch = null
                if (el && el.type === Element.NOTE && el.parent && el.parent.type === Element.CHORD) ch = el.parent
                else if (el && el.type === Element.CHORD) ch = el
                if (!ch) continue
                if (ch.noteType !== NoteType.NORMAL) continue
                if (ch.staffIdx === srcStaffIdx) chords.push(ch)
            }
            // sort by time, then by track (voice) to keep deterministic order
            chords.sort(function(a, b) {
                if (a.fraction.lessThan(b.fraction)) return -1
                if (a.fraction.greaterThan(b.fraction)) return 1
                return a.track - b.track
            })
        }
        return chords
    } // [1](https://stlukes-my.sharepoint.com/personal/ewarren_slhs_org/Documents/Microsoft%20Copilot%20Chat%20Files/keyswitch_creator.txt)

    // Quick check: do we have a selected preset with any active rows in any staff?
    function canApplyToSelection() {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length) return false
        var p = presets[uiRef.selectedIndex]
        if (!p || !p.noteRowsByStaff) return false
        for (var sid in p.noteRowsByStaff) {
            if (!p.noteRowsByStaff.hasOwnProperty(sid)) continue
            var rows = p.noteRowsByStaff[sid] || []
            for (var i = 0; i < rows.length && i < 8; ++i)
                if (rows[i] && rows[i].active) return true
        }
        return false
    }

    // Main entry: apply the current preset to the current selection
    function applyCurrentPresetToSelection() {
        if (!curScore || !curScore.selection) return
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length) return
        var p = presets[uiRef.selectedIndex]
        if (!p || !p.noteRowsByStaff) return

        // Determine source (sketch) staff from the selection
        var srcStaff = -1
        if (curScore.selection.isRange) {
            srcStaff = curScore.selection.startStaff
        } else if (curScore.selection.elements && curScore.selection.elements.length) {
            // take staff of first chord/note in the selection list
            for (var ii = 0; ii < curScore.selection.elements.length; ++ii) {
                var el = curScore.selection.elements[ii]
                if (el && el.staffIdx !== undefined) { srcStaff = el.staffIdx; break }
                if (el && el.parent && el.parent.staffIdx !== undefined) { srcStaff = el.parent.staffIdx; break }
            }
        }
        if (!(srcStaff >= 0)) {
            console.log("[Orchestrator] No sketch staff detected from selection; aborting.")
            return
        }

        // Gather the source chords on that staff within the selection
        var srcChords = collectSourceChordsInSelectionForStaff(srcStaff)
        if (!srcChords.length) return

        // Begin a single undoable command
        curScore.startCmd(qsTr("Orchestrator apply: %1").arg(String(p.name ?? qsTr("Preset"))))
        try {
            // For every source chord, copy rows to every target staff that has them active
            for (var ci = 0; ci < srcChords.length; ++ci) {
                var chord = srcChords[ci]
                var frac = chord.fraction
                var dur = chord.actualDuration
                var num = (dur && dur.numerator) ? dur.numerator : 1
                var den = (dur && dur.denominator) ? dur.denominator : 4

                for (var sidKey in p.noteRowsByStaff) {
                    if (!p.noteRowsByStaff.hasOwnProperty(sidKey)) continue
                    var tgtStaff = parseInt(sidKey, 10)
                    if (isNaN(tgtStaff) || tgtStaff < 0) continue

                    var rows = p.noteRowsByStaff[sidKey] || []
                    // Skip fast if nothing active on this staff
                    var anyActive = false
                    for (var ri = 0; ri < 8 && ri < rows.length; ++ri)
                        if (rows[ri] && rows[ri].active) { anyActive = true; break }
                    if (!anyActive) continue

                    // --- Gather desired pitches per voice at this tick ---
                    var pitchesByVoice = {}   // { "1": [p1,p2,...], "2": [...], ... }
                    for (var row = 0; row < 8 && row < rows.length; ++row) {
                        var spec = rows[row]
                        if (!spec || !spec.active) continue

                        var srcPitch = pitchForRowFromChord(chord, row)
                        if (srcPitch === null || srcPitch === undefined) continue

                        var destPitch = clampInt(srcPitch + Number(spec.offset || 0), 0, 127)
                        var voice = clampInt(Number(spec.voice || 1), 1, 4)
                        var vKey = String(voice)
                        if (!pitchesByVoice[vKey]) pitchesByVoice[vKey] = []

                        // de‑dupe per voice to avoid duplicate adds
                        if (pitchesByVoice[vKey].indexOf(destPitch) === -1)
                            pitchesByVoice[vKey].push(destPitch)
                    }

                    // --- Write for each voice in one pass (stable stacking) ---
                    for (var vKey in pitchesByVoice) {
                        if (!pitchesByVoice.hasOwnProperty(vKey)) continue
                        var list = pitchesByVoice[vKey]
                        if (!list || !list.length) continue

                        var voice = parseInt(vKey, 10)
                        var c2 = curScore.newCursor()
                        c2.track = tgtStaff * 4 + (voice - 1)
                        c2.rewindToFraction(frac)
                        c2.setDuration(num, den)

                        // Ensure a writable slot, then rewind to see the new element
                        var elNow = c2.element
                        var isChord = elNow && elNow.type === Element.CHORD
                        var isRest  = elNow && elNow.type === Element.REST
                        if (!elNow || (!isChord && !isRest)) {
                            ensureWritableSlot(c2, num, den)
                        }
                        c2.rewindToFraction(frac)

                        // First pitch: decide addToChord based on current element
                        var addToChord = !!(c2.element && c2.element.type === Element.CHORD)
                        try { c2.addNote(list[0], addToChord) } catch (eAdd0) {}

                        // Remaining pitches: force stacking into the same chord
                        for (var k = 1; k < list.length; ++k) {
                            c2.rewindToFraction(frac)
                            try { c2.addNote(list[k], true) } catch (eAddN) {}
                        }
                        try {
                            console.log("[Orchestrator] write @tick", frac.ticks, "staff", tgtStaff, "voice", voice, "pitches", list.join(","))
                        } catch (eDbg) {}
                    }
                }
            }
        } catch (e) {
            curScore.endCmd(true)
            console.log("[Orchestrator] ERROR:", String(e))
            return
        }
        curScore.endCmd()
    }

    // Apply a specific preset card (by index) to the current selection without
    // changing the UI selection. Mirrors applyCurrentPresetToSelection().
    function applyPresetIndexToSelection(index) {
        if (!curScore || !curScore.selection) return
        if (!(index >= 0 && index < presets.length)) return

        var p = presets[index]
        if (!p || !p.noteRowsByStaff) return

        // Determine source (sketch) staff from the selection
        var srcStaff = -1
        if (curScore.selection.isRange) {
            srcStaff = curScore.selection.startStaff
        } else if (curScore.selection.elements && curScore.selection.elements.length) {
            for (var ii = 0; ii < curScore.selection.elements.length; ++ii) {
                var el = curScore.selection.elements[ii]
                if (el && el.staffIdx !== undefined) { srcStaff = el.staffIdx; break }
                if (el && el.parent && el.parent.staffIdx !== undefined) { srcStaff = el.parent.staffIdx; break }
            }
        }
        if (!(srcStaff >= 0)) return

        // Collect source chords (normal notes) on that staff within selection
        var srcChords = collectSourceChordsInSelectionForStaff(srcStaff)
        if (!srcChords.length) return

        curScore.startCmd(qsTr("Orchestrator apply: %1").arg(String(p.name ?? qsTr("Preset"))))
        try {
            for (var ci = 0; ci < srcChords.length; ++ci) {
                var chord = srcChords[ci]
                var frac = chord.fraction
                var dur  = chord.actualDuration
                var num = (dur && dur.numerator)   ? dur.numerator   : 1
                var den = (dur && dur.denominator) ? dur.denominator : 4

                for (var sidKey in p.noteRowsByStaff) {
                    if (!p.noteRowsByStaff.hasOwnProperty(sidKey)) continue
                    var tgtStaff = parseInt(sidKey, 10)
                    if (isNaN(tgtStaff) || tgtStaff < 0) continue

                    var rows = p.noteRowsByStaff[sidKey] || []
                    var anyActive = false
                    for (var ri = 0; ri < 8 && ri < rows.length; ++ri)
                        if (rows[ri] && rows[ri].active) { anyActive = true; break }
                    if (!anyActive) continue

                    // --- Gather desired pitches per voice at this tick ---
                    var pitchesByVoice = {}
                    for (var row = 0; row < 8 && row < rows.length; ++row) {
                        var spec = rows[row]
                        if (!spec || !spec.active) continue

                        var srcPitch = pitchForRowFromChord(chord, row)
                        if (srcPitch === null || srcPitch === undefined) continue

                        var destPitch = clampInt(srcPitch + Number(spec.offset || 0), 0, 127)
                        var voice = clampInt(Number(spec.voice || 1), 1, 4)
                        var vKey = String(voice)
                        if (!pitchesByVoice[vKey]) pitchesByVoice[vKey] = []
                        if (pitchesByVoice[vKey].indexOf(destPitch) === -1)
                            pitchesByVoice[vKey].push(destPitch)
                    }

                    // --- Write for each voice in one pass ---
                    for (var vKey in pitchesByVoice) {
                        if (!pitchesByVoice.hasOwnProperty(vKey)) continue
                        var list = pitchesByVoice[vKey]
                        if (!list || !list.length) continue

                        var voice = parseInt(vKey, 10)
                        var c2 = curScore.newCursor()
                        c2.track = tgtStaff * 4 + (voice - 1)
                        c2.rewindToFraction(frac)
                        c2.setDuration(num, den)

                        var elNow = c2.element
                        var isChord = elNow && elNow.type === Element.CHORD
                        var isRest  = elNow && elNow.type === Element.REST
                        if (!elNow || (!isChord && !isRest)) {
                            ensureWritableSlot(c2, num, den)
                        }
                        c2.rewindToFraction(frac)

                        var addToChord = !!(c2.element && c2.element.type === Element.CHORD)
                        try { c2.addNote(list[0], addToChord) } catch (eAdd0) {}
                        for (var k = 1; k < list.length; ++k) {
                            c2.rewindToFraction(frac)
                            try { c2.addNote(list[k], true) } catch (eAddN) {}
                        }
                        try {
                            console.log("[Orchestrator] write @tick", frac.ticks, "staff", tgtStaff, "voice", voice, "pitches", list.join(","))
                        } catch (eDbg) {}
                    }
                }
            }

        } catch (e) {
            curScore.endCmd(true)
            console.log("[Orchestrator] ERROR:", String(e))
            return
        }
        curScore.endCmd()
    }

    // Model: { idx, name }
    ListModel { id: staffListModel }

    // --- Helpers (adapted from keyswitch_creator_settings.qml) ---
    function bumpSelection() {
        selectedCountProp = Object.keys(selectedStaff).length
    }

    function clearSelection() {
        selectedStaff = ({})
        bumpSelection()
    }

    function isRowSelected(rowIndex) {
        if (rowIndex < 0 || rowIndex >= staffListModel.count) return false
        var sIdx = staffListModel.get(rowIndex).idx
        return !!selectedStaff[sIdx]
    }

    function setRowSelected(rowIndex, on) {
        if (rowIndex < 0 || rowIndex >= staffListModel.count) return
        var sIdx = staffListModel.get(rowIndex).idx
        var ns = Object.assign({}, selectedStaff)
        if (on) ns[sIdx] = true
        else delete ns[sIdx]
        selectedStaff = ns
        bumpSelection()
    }

    function toggleRow(rowIndex) {
        var was = isRowSelected(rowIndex)
        setRowSelected(rowIndex, !was)
        lastAnchorIndex = rowIndex
        currentStaffIdx = staffListModel.get(rowIndex).idx
        if (selectedCountProp === 0) setRowSelected(rowIndex, true)
    }

    function selectSingle(rowIndex) {
        clearSelection()
        setRowSelected(rowIndex, true)
        lastAnchorIndex = rowIndex
        currentStaffIdx = staffListModel.get(rowIndex).idx
    }

    function selectRange(rowIndex) {
        if (lastAnchorIndex < 0) { selectSingle(rowIndex); return }
        var a = Math.min(lastAnchorIndex, rowIndex)
        var b = Math.max(lastAnchorIndex, rowIndex)
        clearSelection()
        for (var r = a; r <= b; ++r) setRowSelected(r, true)
        currentStaffIdx = staffListModel.get(rowIndex).idx
    }

    function selectAll() {
        clearSelection()
        for (var r = 0; r < staffListModel.count; ++r) setRowSelected(r, true)
        var sl = orchestratorWin ? orchestratorWin.staffListRef : null
        if (sl && sl.currentIndex < 0 && staffListModel.count > 0)
            sl.currentIndex = 0
    }

    // --- Name/score helpers (trimmed to what's needed for the list) ---
    function stripHtmlTags(s) { return String(s || "").replace(/\<[^>]*\>/g, "") }
    function decodeHtmlEntities(s) {
        var t = String(s || "")
        t = t.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'")
        t = t.replace(/&#([0-9]+);/g, function(_, n) { return String.fromCharCode(parseInt(n, 10) || 0) })
        t = t.replace(/&#x([0-9a-fA-F]+);/g, function(_, h) { return String.fromCharCode(parseInt(h, 16) || 0) })
        return t
    }
    function cleanName(s) { return String(s || '').split('\r\n').join(' ').split('\n').join(' ') }
    function normalizeUiText(s) { return cleanName(decodeHtmlEntities(stripHtmlTags(s))) }

    function staffBaseTrack(staffIdx) { return staffIdx * 4 }

    function nameForPart(p, tick) {
        if (!p) return ''
        var nm = (p.longName && p.longName.length) ? p.longName
                                                   : (p.partName && p.partName.length) ? p.partName
                                                                                       : (p.shortName && p.shortName.length) ? p.shortName : ''
        if (!nm && p.instrumentAtTick) {
            var inst = p.instrumentAtTick(tick || 0)
            if (inst && inst.longName && inst.longName.length) nm = inst.longName
        }
        return normalizeUiText(nm)
    }

    function partForStaff(staffIdx) {
        if (!curScore || !curScore.parts) return null
        var t = staffBaseTrack(staffIdx)
        for (var i = 0; i < curScore.parts.length; ++i) {
            var p = curScore.parts[i]
            if (t >= p.startTrack && t < p.endTrack) return p
        }
        return null
    }

    function staffNameByIdx(staffIdx) {
        for (var i = 0; i < staffListModel.count; ++i) {
            var item = staffListModel.get(i)
            if (item && item.idx === staffIdx) return cleanName(item.name)
        }
        var base = nameForPart(partForStaff(staffIdx), 0) || 'Unknown instrument'
        return cleanName(base + ': ' + qsTr('Staff %1').arg(1))
    }

    function buildStaffListModel() {
        staffListModel.clear()
        if (curScore && curScore.parts) {
            for (var pIdx = 0; pIdx < curScore.parts.length; ++pIdx) {
                var p = curScore.parts[pIdx]
                var baseStaff = Math.floor(p.startTrack / 4)
                var numStaves = Math.floor((p.endTrack - p.startTrack) / 4)
                var partName = nameForPart(p, 0)
                var cleanPart = cleanName(partName)
                for (var sOff = 0; sOff < numStaves; ++sOff) {
                    var staffIdx = baseStaff + sOff
                    var display = cleanPart + ': ' + qsTr('Staff %1').arg(sOff + 1)
                    staffListModel.append({ idx: staffIdx, name: display })
                }
            }
        }
        // Do not auto-select any staff on open
        var sl = orchestratorWin ? orchestratorWin.staffListRef : null
        if (sl) sl.currentIndex = -1
        clearSelection()
    }

    // Ensure the list is populated and the window is visible when the plugin opens
    onRun: {
        console.log("Orchestrator: onRun()")
        if (!orchestratorWin) {
            orchestratorWin = orchestratorWinComponent.createObject(root)
            console.log("Orchestrator: window created:", orchestratorWin)
        }

        // ---------- Restore UI state (pre-show, no flicker) ----------
        try {
            // Restore Settings panel state FIRST (drives width policy)
            root.settingsOpen = !!ocPrefs.lastSettingsOpen;

            // Width locked to either base or expanded; mirror your toggle math
            var targetW = root.settingsOpen ? (root.baseWidth + 607) : root.baseWidth;
            orchestratorWin.minimumWidth = targetW;
            orchestratorWin.maximumWidth = targetW;
            orchestratorWin.width        = targetW;

            // Restore height (clamped to minimum)
            var minH = orchestratorWin.minimumHeight || 380;
            var savedH = Number(ocPrefs.lastWindowHeight || 0);
            if (savedH > 0) {
                orchestratorWin.height = Math.max(minH, savedH);
            }

            // Restore gridView before we populate cards (affects layout widths)
            root.gridView = !!ocPrefs.lastGridView;
            // Restore position pre-show (best-effort; clamped again post-show)
            try {
                var savedX = Number(ocPrefs.lastWindowX);
                var savedY = Number(ocPrefs.lastWindowY);
                var haveSavedPos = !(isNaN(savedX) || isNaN(savedY)) && (savedX !== 0 || savedY !== 0);

                if (haveSavedPos) {
                    orchestratorWin.x = savedX;
                    orchestratorWin.y = savedY;
                    orchestratorWin._centeredOnce = true; // hard-disable any centering this session
                }
            } catch (e) {}
        } catch (e) {
            console.log("[Orchestrator] Restore UI state failed:", String(e));
        }
        // -----------------------------------------------

        // Explicitly show/raise/activate the window and set its visibility state
        orchestratorWin.visibility = Window.Windowed
        orchestratorWin.show()
        orchestratorWin.raise()
        orchestratorWin.requestActivate()

        Qt.callLater(function () {
            // --- Restore window position (ensure on-screen) ---
            try {
                var s = orchestratorWin ? orchestratorWin.screen : null;
                var r = s ? (s.availableGeometry || s.geometry) : null;

                var savedX = Number(ocPrefs.lastWindowX);
                var savedY = Number(ocPrefs.lastWindowY);
                var haveSaved = !(isNaN(savedX) || isNaN(savedY));

                if (r && haveSaved) {
                    // Clamp the window so at least the title area remains visible.
                    var minW = Math.max(100, orchestratorWin.width);
                    var minH = Math.max(80, orchestratorWin.minimumHeight || 80);

                    var minX = r.x;
                    var maxX = r.x + Math.max(0, r.width  - minW);
                    var minY = r.y;
                    var maxY = r.y + Math.max(0, r.height - minH);

                    orchestratorWin.x = Math.max(minX, Math.min(maxX, savedX));
                    orchestratorWin.y = Math.max(minY, Math.min(maxY, savedY));
                }
            } catch (e) {
                console.log("[Orchestrator] Restore window position failed:", String(e));
            }
            // ---------------------------------------------------

            console.log("Orchestrator: post-show visible =", orchestratorWin.visible,
                        "visibility =", orchestratorWin.visibility)
            buildStaffListModel()
            // Load presets (Settings-backed) and apply the first preset to the UI
            loadPresetsFromSettings()
            // --- Restore selected card (only when Settings panel is open) ---
            try {
                var model = orchestratorWin ? orchestratorWin.allPresetsModelRef : null;
                var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;

                if (root.settingsOpen && model && uiRef) {
                    var stored = ocPrefs.lastSelectedIndex;
                    var hasStored = (stored !== undefined && stored !== null && stored >= 0);
                    var clamped  = (hasStored && model.count > 0) ? Math.min(stored, model.count - 1) : -1;

                    // Ensure our restore wins, regardless of earlier auto-selects.
                    uiRef.selectedIndex = -1;
                    if (clamped >= 0) {
                        Qt.callLater(function () {
                            uiRef.selectedIndex = clamped;   // applyPresetToUI() updates title immediately
                        });
                    }
                } else if (uiRef) {
                    uiRef.selectedIndex = -1; // normal mode: no persistent selection
                }
            } catch (e) {
                console.log("[Orchestrator] Restore selected card failed:", String(e));
            }
        })
    }

    // ----- Self-managed top-level window for Orchestrator -----
    Component {
        id: orchestratorWinComponent
        Window {
            id: win
            // Make absolutely sure the window is treated as a normal, non-modal top-level window
            visibility: Window.Windowed
            modality: Qt.NonModal
            title: qsTr("Orchestrator")

            // Expose inner objects to root (so root-level helpers can reach them)
            property alias rootUIRef: rootUI
            property alias allPresetsModelRef: allPresetsModel
            property alias staffListRef: staffList
            property alias presetTitleFieldRef: presetTitleField
            property alias noteButtonsPaneRef: noteButtonsPane

            // Valid bitmask so the OS shows real resize affordances
            flags: Qt.Window
                   | Qt.WindowTitleHint
                   | Qt.WindowSystemMenuHint
                   | Qt.WindowMinMaxButtonsHint
                   | Qt.WindowCloseButtonHint
                   | Qt.WindowStaysOnTopHint

            color: ui.theme.backgroundPrimaryColor
            property var pluginRoot: root
            property bool _centeredOnce: false

            function centerOnce() {
                if (_centeredOnce) return;

                // NEW: if we have a saved position, never center.
                var haveSavedPos = (ocPrefs && ((ocPrefs.lastWindowX !== 0) || (ocPrefs.lastWindowY !== 0)));
                if (haveSavedPos) { _centeredOnce = true; return; }

                var s = win.screen;
                if (!s) return; // not on a screen yet

                var r = s.availableGeometry || s.geometry;
                if (!r) return;

                win.x = r.x + Math.max(0, (r.width  - win.width)  / 2);
                win.y = r.y + Math.max(0, (r.height - win.height) / 2);
                _centeredOnce = true;
            }

            onScreenChanged:  Qt.callLater(centerOnce)

            // Lock horizontal drag; allow vertical drag
            width: baseWidth
            minimumWidth:  baseWidth
            maximumWidth:  baseWidth
            minimumHeight: 380

            // Save height while visible, so drag-resize is captured
            onHeightChanged: {
                if (visible) {
                    try { ocPrefs.lastWindowHeight = height; } catch (e) {}
                }
            }

            onXChanged: if (visible) { try { ocPrefs.lastWindowX = x; } catch (e) {} }
            onYChanged: if (visible) { try { ocPrefs.lastWindowY = y; } catch (e) {} }

            // Also save on hide/close, as a final safety (and the current Settings state)
            onVisibleChanged: {
                // Center only if we don't have a saved position
                if (visible) {
                    var haveSavedPos = ((ocPrefs.lastWindowX !== 0) || (ocPrefs.lastWindowY !== 0));
                    if (!haveSavedPos) Qt.callLater(centerOnce);
                }
                if (!visible) {
                    try {
                        ocPrefs.lastWindowHeight = height;
                        ocPrefs.lastSettingsOpen = root.settingsOpen;
                        ocPrefs.lastWindowX = x;
                        ocPrefs.lastWindowY = y;
                        if (ocPrefs.sync) ocPrefs.sync();
                    } catch (e) {}
                }
            }
            // leave maximumHeight unconstrained

            // Close the plugin when the window is hidden/closed (portable across environments)
            // onVisibleChanged: {
            //     if (!visible) Qt.quit()
            // }

            // Width animation: target this Window's width
            PropertyAnimation {
                id: winWidthAnim
                target: orchestratorWin
                property: "width"
                duration: 250
                easing.type: Easing.InOutQuad
            }


            //--------------------------------------------------------------------------------
            // UI
            //--------------------------------------------------------------------------------
            ColumnLayout {
                id: rootUI
                // Keep the left panel at the base width and anchor it to the left,
                // so widening the host window does not stretch this column.
                width: root.baseWidth
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.margins: 12
                spacing: 10

                // Single source of truth for side padding inside the left panel
                readonly property int panelSidePadding: 8

                // Fine-tuning:
                //  - Trim a couple of pixels from card width to make left/right gutters look symmetric at base width
                readonly property int cardRightTrim: 8
                //  - Push toolbar icons slightly more left than the cards (visual rhythm)
                readonly property int iconExtraRightMargin: 16

                // --- Sprint 1 data & filtering ---
                property string setFilterText: ""
                // Single-selection: -1 = none, otherwise model index in allPresetsModel
                property int selectedIndex: -1
                // Backing model of all presets (placeholder content for Sprint 1)
                ListModel {
                    id: allPresetsModel
                    ListElement { name: "Wind Ensemble";  count: 3; staves: "Flutes, Oboes, Bassoons" }
                }

                onSelectedIndexChanged: {
                    if (!root.suppressApplyPreset &&
                            !root.creatingNewPreset &&
                            selectedIndex >= 0 &&
                            selectedIndex < allPresetsModel.count)
                    {
                        applyPresetToUI(selectedIndex);
                    }

                    // Persist selection (unchanged)
                    try {
                        ocPrefs.lastSelectedIndex = root.settingsOpen
                                ? Math.max(-1, Math.min(selectedIndex, allPresetsModel.count - 1))
                                : -1;
                        if (ocPrefs.sync) ocPrefs.sync();
                    } catch (e) {}
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    //Layout.leftMargin:  rootUI.panelSidePadding
                    Layout.rightMargin: presetScroll.rightPadding + rootUI.iconExtraRightMargin

                    // --- Preset filter (matches your Keyswitch Creator behavior) ---
                    SearchField {
                        id: setSearchField
                        Layout.preferredWidth: 150
                        hint: qsTr("Filter sets")
                        function _readSearchText() {
                            var v = setSearchField.text !== undefined ? setSearchField.text
                                                                      : (setSearchField.value !== undefined ? setSearchField.value
                                                                                                            : (setSearchField.displayText !== undefined ? setSearchField.displayText : ""));
                            return (typeof v === "string") ? v : "";
                        }
                        onTextChanged: function (val) {
                            rootUI.setFilterText = (typeof val === "string") ? val : _readSearchText();
                        }
                        onTextEdited: function (val) {
                            rootUI.setFilterText = (typeof val === "string") ? val : _readSearchText();
                        }
                    }

                    Item { Layout.fillWidth: true }


                    FlatButton {
                        id: cardView
                        icon: root.gridView ? IconCode.SPLIT_VIEW_VERTICAL : IconCode.GRID
                        //toolTip: qsTr("Add preset (placeholder)")
                        onClicked: {
                            root.gridView = !root.gridView

                        }
                    }

                    FlatButton {
                        id: settingsBtn
                        icon: IconCode.SETTINGS_COG
                        accentButton: root.settingsOpen
                        onClicked: {
                            root.settingsOpen = !root.settingsOpen

                            try { ocPrefs.lastSettingsOpen = root.settingsOpen; if (ocPrefs.sync) ocPrefs.sync(); } catch (e) {}

                            if (!root.settingsOpen && rootUI) {
                                rootUI.selectedIndex = -1
                            }

                            // When opening settings, auto-select first card if none selected
                            if (root.settingsOpen && rootUI && rootUI.selectedIndex < 0) {
                                rootUI.selectedIndex = 0
                                applyPresetToUI(0)
                            }

                            const startW  = orchestratorWin.width
                            const targetW = root.settingsOpen ? (root.baseWidth + 607) : root.baseWidth

                            // Temporarily allow animation range, then re-lock to targetW
                            orchestratorWin.minimumWidth = Math.min(startW, targetW)
                            orchestratorWin.maximumWidth = Math.max(startW, targetW)

                            winWidthAnim.stop()
                            winWidthAnim.to = targetW

                            winWidthAnim.onFinished.connect(function relockOnce() {
                                winWidthAnim.onFinished.disconnect(relockOnce)
                                orchestratorWin.minimumWidth = targetW
                                orchestratorWin.maximumWidth = targetW
                            })

                            winWidthAnim.start()
                        }
                    }
                }

                // --- Presets list (wraps down the window) ---
                ScrollView {
                    id: presetScroll
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    padding: rootUI.panelSidePadding

                    Flickable {
                        id: presetFlick
                        anchors.fill: parent
                        contentWidth: presetsFlow.implicitWidth
                        contentHeight: presetsFlow.implicitHeight
                        clip: true

                        Flow {
                            id: presetsFlow
                            width: Math.floor(presetScroll.availableWidth) - rootUI.cardRightTrim
                            spacing: 8

                            // --- NEW: adaptive grid support (1-up vs 2-up) ---
                            // When root.gridView is true -> 2 columns; otherwise 1 column (full width).
                            // We compute card width so two cards fit in one row with Flow.spacing between them.
                            property int cardsPerRow: root.gridView ? 2 : 1
                            readonly property int columnSpacing: spacing
                            function cardWidth() {
                                var cols = Math.max(1, cardsPerRow)
                                var totalW = Math.max(0, width)
                                // totalW = (cols * cardW) + (cols - 1) * spacing
                                return Math.floor((totalW - columnSpacing * (cols - 1)) / cols)
                            }

                            Repeater {
                                id: presetRepeater
                                model: allPresetsModel
                                delegate: Rectangle {
                                    id: card
                                    // Cards are only "selectable" when settings panel is open
                                    property bool selected: root.settingsOpen && (rootUI.selectedIndex === model.index)
                                    property bool matchesFilter: {
                                        var t = rootUI.setFilterText;
                                        if (!t || t.length === 0)
                                            return true;
                                        var f = t.toLowerCase();
                                        return (name.toLowerCase().indexOf(f) !== -1)
                                                || (staves.toLowerCase().indexOf(f) !== -1);
                                    }
                                    visible: matchesFilter

                                    // NEW: width adapts to single- or two-column layout
                                    width: presetsFlow.cardWidth()
                                    // Keep the height as-is (mock shows short cards)
                                    height: root.gridView ? 120 : 100
                                    Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

                                    radius: 3

                                    // Smooth transition when toggling gridView
                                    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

                                    // Container itself stays fully opaque; the background below handles color/opacity.
                                    color: "transparent"
                                    clip: true

                                    Rectangle {
                                        id: cardBg
                                        anchors.fill: parent
                                        radius: parent.radius

                                        // Whether the preset has a custom background color
                                        property bool hasCustomColor: {
                                            var p = root.presets && root.presets[model.index];
                                            return (p && p.backgroundColor && String(p.backgroundColor).length);
                                        }

                                        // Whether this card is selected for editing
                                        property bool isSelectedInSettings: (root.settingsOpen && card.selected)

                                        // Background color: custom first, otherwise neutral buttonColor
                                        property color baseColor: {
                                            if (hasCustomColor)
                                                return root.presets[model.index].backgroundColor;
                                            return ui.theme.buttonColor;
                                        }

                                        color: baseColor

                                        // ✔ NEW: Selected card always has border in settings mode
                                        border.width: (isSelectedInSettings ? 2 : 0)
                                        border.color: ui.theme.fontPrimaryColor
                                    }

                                    // Visual states now target the background only (never the content)
                                    states: [
                                        State {
                                            name: "NORMAL"
                                            when: !mouseArea.containsMouse

                                            PropertyChanges {
                                                target: cardBg
                                                opacity: {
                                                    var p = root.presets && root.presets[model.index]
                                                            ? root.presets[model.index] : null;
                                                    var hasCustom = p && p.backgroundColor && String(p.backgroundColor).length;

                                                    if (root.settingsOpen && card.selected && !hasCustom)
                                                        return ui.theme.accentOpacityNormal;

                                                    return ui.theme.buttonOpacityNormal;
                                                }
                                            }
                                        },
                                        State {
                                            name: "PRESSED"
                                            when: mouseArea.pressed
                                            PropertyChanges {
                                                target: cardBg
                                                opacity: {
                                                    var p = root.presets && root.presets[model.index]
                                                            ? root.presets[model.index] : null;
                                                    var hasCustom = p && p.backgroundColor && String(p.backgroundColor).length;

                                                    // Prefer the accent "hit" token for selected/no-custom if available
                                                    var accentHit = (ui.theme.accentOpacityHit !== undefined)
                                                            ? ui.theme.accentOpacityHit
                                                            : ui.theme.buttonOpacityHit;

                                                    if (root.settingsOpen && card.selected && !hasCustom)
                                                        return accentHit;

                                                    // For custom color cards (and all others), show a clear "hit"
                                                    return ui.theme.buttonOpacityHit;
                                                }
                                            }
                                        },
                                        State {
                                            name: "HOVERED"
                                            when: mouseArea.containsMouse && !mouseArea.pressed
                                            PropertyChanges {
                                                target: cardBg
                                                opacity: {
                                                    var p = root.presets && root.presets[model.index]
                                                            ? root.presets[model.index] : null;
                                                    var hasCustom = p && p.backgroundColor && String(p.backgroundColor).length;

                                                    return hasCustom
                                                            ? ui.theme.buttonOpacityHover
                                                            : ui.theme.buttonOpacityHover;
                                                }
                                            }
                                        }
                                    ]

                                    // Card content
                                    Column {
                                        id: cardContent
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        spacing: 6

                                        RowLayout {
                                            id: headerRow
                                            width: parent.width
                                            // List view: keep a balanced gap; Grid view: tighten a bit so the title elides later
                                            spacing: root.gridView ? Math.max(6, cardContent.anchors.margins - 2)
                                                                   : cardContent.anchors.margins

                                            // Name (display only) — clean single line with tail elide
                                            Label {
                                                id: nameLabel
                                                text: model.name
                                                color: ui.theme.fontPrimaryColor
                                                font.bold: true
                                                font.pixelSize: 14
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                                clip: true
                                                Layout.fillWidth: true
                                                Layout.alignment: Qt.AlignVCenter
                                                verticalAlignment: Text.AlignVCenter
                                            }

                                            // RIGHT-ALIGNED COUNT — wider slot, left-elided if very long
                                            Text {
                                                id: countText
                                                text: model.count
                                                color: ui.theme.fontPrimaryColor
                                                font.bold: true
                                                font.pixelSize: 14

                                                // Let the tally size to its content so the title gets maximum room
                                                Layout.preferredWidth: implicitWidth
                                                Layout.minimumWidth: implicitWidth
                                                Layout.maximumWidth: implicitWidth
                                                elide: Text.ElideLeft
                                                clip: true
                                                maximumLineCount: 1
                                                horizontalAlignment: Text.AlignRight
                                                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                                            }
                                        }

                                        // Second row: staves list — measured truncation within 4 lines, ending with " more..."
                                        Item {
                                            id: stavesWrap
                                            width: parent.width
                                            height: Math.max(0, cardContent.height - headerRow.height - cardContent.spacing)
                                            clip: true

                                            // Config
                                            readonly property int maxLines: root.gridView ? 5 : 4
                                            property string fullStaves: model.staves
                                            property string displayStaves: fullStaves

                                            // Hidden measurer: same width/font/wrap as the real text; used to test fit
                                            Text {
                                                id: stavesMeasure
                                                visible: false
                                                width: stavesWrap.width
                                                wrapMode: Text.WordWrap
                                                elide: Text.ElideNone
                                                font.pixelSize: 12
                                            }

                                            // Compute the longest word-prefix that fits with " more..." inside maxLines
                                            function recompute() {
                                                var base = String(fullStaves || "")
                                                // Defer until we have geometry
                                                if (stavesWrap.width <= 0 || stavesWrap.height <= 0) {
                                                    // Capture THIS instance so we don't chase a recycled delegate later
                                                    var self = stavesWrap
                                                    Qt.callLater(function () {
                                                        if (self && typeof self.recompute === "function")
                                                            self.recompute()
                                                    })
                                                    return
                                                }

                                                // Try full text first: if it fits within maxLines, keep it
                                                stavesMeasure.text = base
                                                if (stavesMeasure.lineCount <= maxLines) {
                                                    displayStaves = base
                                                    return
                                                }

                                                // Otherwise binary-search the maximum number of words that fit with " more..."
                                                var words = base.split(/\s+/)
                                                var lo = 0, hi = words.length, fit = 0
                                                var suffix = " more..."

                                                while (lo <= hi) {
                                                    var mid = Math.floor((lo + hi) / 2)
                                                    var candidate = (mid > 0 ? words.slice(0, mid).join(" ") + suffix : "more...")
                                                    stavesMeasure.text = candidate

                                                    if (stavesMeasure.lineCount <= maxLines) {
                                                        fit = mid
                                                        lo = mid + 1
                                                    } else {
                                                        hi = mid - 1
                                                    }

                                                }

                                                var out = (fit > 0 ? words.slice(0, fit).join(" ") + suffix : "more...")
                                                displayStaves = out
                                            }

                                            // Recompute on size/data changes and after grid toggles
                                            onWidthChanged: recompute()
                                            onHeightChanged: recompute()
                                            onFullStavesChanged: recompute()
                                            Component.onCompleted: stavesWrap.recompute()
                                            Connections { target: root; function onGridViewChanged() { stavesWrap.recompute() } }

                                            // Actual displayed text (multi-line, no overlay ellipsis)
                                            Text {
                                                id: stavesText
                                                anchors.fill: parent
                                                text: stavesWrap.displayStaves
                                                color: ui.theme.fontPrimaryColor
                                                wrapMode: Text.WordWrap
                                                elide: Text.ElideNone
                                                font.pixelSize: 12
                                                clip: true
                                            }
                                        }}

                                    MouseArea {
                                        id: mouseArea
                                        anchors.fill: parent
                                        enabled: root.enabled
                                        hoverEnabled: true

                                        // Allow child controls (e.g., TextInput) to receive the actual click
                                        propagateComposedEvents: true

                                        onPressed: function(mouse) {
                                            // Only select cards when settings panel is open
                                            if (root.settingsOpen) {
                                                rootUI.selectedIndex = model.index
                                            }
                                            ui.tooltip.hide(root, true)
                                        }

                                        preventStealing: true

                                        onClicked: {
                                            // Normal mode: fire this preset immediately on current selection
                                            if (!root.settingsOpen) {
                                                root.applyPresetIndexToSelection(model.index)
                                                // trigger-only, no selection persistence
                                                rootUI.selectedIndex = -1
                                                return
                                            }
                                            // Settings-open behavior remains selection of the card (handled in onPressed)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Optional: a subtle vertical separator at the right edge of the fixed panel
            // AFTER   (robust: anchor to rootUI.right)
            Rectangle {
                id: settingsSeparator
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: rootUI.right          // stick to the right edge of the left panel
                anchors.leftMargin: -13             // the same visual inset as before
                width: 1
                color: ui.theme.strokeColor

                // Use a fixed gap; the old computed expression depended on 'x' prematurely
                property int sideGap: 13
            }

            // --- New: narrow tools column just to the right of the separator ---
            ColumnLayout {
                id: settingsTools
                anchors.left: settingsSeparator.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: settingsSeparator.sideGap
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 10

                // Fixed narrow width to keep a clean vertical toolbar look
                readonly property int toolSize: 28
                width: toolSize + 8

                // Smoothly keep the selected card in view after reordering.
                // Runs after the Flow finished its relayout so 'itemAt(idx).y' is final.
                function scrollCardIntoView(idx) {
                    if (idx < 0 || idx >= presetRepeater.count)
                        return;

                    // Let Flow/Repeater finish creating the delegate first.
                    Qt.callLater(function () {
                        var it = presetRepeater.itemAt(idx);
                        if (!it || typeof it.y !== "number" || typeof it.height !== "number") {
                            // Try once more after the layout settles; bail if still not ready.
                            Qt.callLater(function () {
                                var it2 = presetRepeater.itemAt(idx);
                                if (!it2 || typeof it2.y !== "number" || typeof it2.height !== "number")
                                    return;

                                var top2 = it2.y;
                                var bottom2 = top2 + it2.height;
                                var viewTop2 = presetFlick.contentY;
                                var viewBottom2 = viewTop2 + presetFlick.height;
                                var newY2 = viewTop2;

                                if (top2 < viewTop2) newY2 = top2 - 8;
                                else if (bottom2 > viewBottom2) newY2 = bottom2 - presetFlick.height + 8;

                                var maxY2 = Math.max(0, presetFlick.contentHeight - presetFlick.height);
                                presetFlick.contentY = Math.max(0, Math.min(maxY2, newY2));
                            });
                            return;
                        }

                        var top = it.y;
                        var bottom = top + it.height;
                        var viewTop = presetFlick.contentY;
                        var viewBottom = viewTop + presetFlick.height;
                        var newY = viewTop;

                        if (top < viewTop) newY = top - 8;
                        else if (bottom > viewBottom) newY = bottom - presetFlick.height + 8;

                        var maxY = Math.max(0, presetFlick.contentHeight - presetFlick.height);
                        presetFlick.contentY = Math.max(0, Math.min(maxY, newY));
                    });
                }

                FlatButton {
                    id: presetSaveButton

                    accentButton: true
                    icon: IconCode.SAVE
                    //toolTip: qsTr("Add preset (placeholder)")
                    onClicked: {
                        saveCurrentPreset()
                        console.log("[Orchestrator] Preset saved:", presetTitleField.text)
                    }
                }

                FlatButton {
                    icon: IconCode.PLUS
                    //toolTip: qsTr("Add preset (placeholder)")
                    onClicked: {
                        // Begin a short transaction: block any live-commit noise and auto-apply paths
                        root.creatingNewPreset = true;              // transaction guard ON
                        var prevCommit = root.liveCommitEnabled;
                        root.liveCommitEnabled = false;
                        root.suppressApplyPreset = true;

                        // Force a real selection break so QML tears down old bindings
                        rootUI.selectedIndex = -1;

                        // --- 1) Create and insert a truly empty preset (no staves/rows) ---
                        var p = newPresetObject(qsTr("New Preset"));
                        presets.unshift(p);
                        refreshPresetsListModel();
                        presetFlick.contentY = 0;

                        // --- 2) Clear ALL selection state in the UI ---
                        clearSelection(); // staff multi-select map
                        if (orchestratorWin && orchestratorWin.staffListRef)
                            orchestratorWin.staffListRef.currentIndex = -1;

                        // Hard reset the 8-row note-buttons UI (no commits fired during reset)
                        resetNoteButtonsUI();

                        // --- 3) Select the new card without auto-applying ---
                        rootUI.selectedIndex = 0;

                        // --- 4) Apply exactly once, with no staff focused -> note UI remains empty
                        applyPresetToUI(0);

                        // (Optional hard sanitize: guarantee the new preset stayed empty)
                        var np = presets[0];
                        np.noteRowsByStaff = {};
                        np.staves = [];
                        notifyPresetsMutated();
                        refreshPresetsListModel();

                        // Restore commit policy now (but keep the creation guard ON one more tick)
                        root.suppressApplyPreset = false;
                        root.liveCommitEnabled = prevCommit;

                        // Delay releasing the guard to outlive any Qt.callLater() that may still fire
                        Qt.callLater(function () {
                            root.creatingNewPreset = false;        // transaction guard OFF
                        });

                        // Persist
                        savePresetsToSettings();
                    }
                }

                FlatButton {
                    icon: IconCode.ARROW_UP
                    enabled: (rootUI.selectedIndex > 0)
                    //toolTip: qsTr("Move preset up")
                    onClicked: {
                        const i = rootUI.selectedIndex
                        const last = allPresetsModel.count - 1
                        if (i <= 0 || i > last) return
                        // Move in the UI
                        allPresetsModel.move(i, i - 1, 1)
                        // Mirror move in presets[]
                        var tmp = presets[i - 1]; presets[i - 1] = presets[i]; presets[i] = tmp
                        notifyPresetsMutated()
                        rootUI.selectedIndex = i - 1
                        settingsTools.scrollCardIntoView(i - 1)
                        savePresetsToSettings()
                    }
                }

                FlatButton {
                    icon: IconCode.ARROW_DOWN
                    enabled: (rootUI.selectedIndex >= 0 && rootUI.selectedIndex < allPresetsModel.count - 1)
                    //toolTip: qsTr("Move preset down")
                    onClicked: {
                        const i = rootUI.selectedIndex
                        const last = allPresetsModel.count - 1
                        if (i < 0 || i >= last) return
                        allPresetsModel.move(i, i + 1, 1)
                        var tmp = presets[i + 1]; presets[i + 1] = presets[i]; presets[i] = tmp
                        notifyPresetsMutated()
                        rootUI.selectedIndex = i + 1
                        settingsTools.scrollCardIntoView(i + 1)
                        savePresetsToSettings()
                    }
                }

                FlatButton {
                    icon: IconCode.BRUSH
                    onClicked: {
                        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                        // var dlg = cardColorDialogComponent.createObject(rootUI, {});
                        // dlg.colorPicked.connect(function(hex) {
                        //     var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                        //     if (sel >= 0 && sel < presets.length) {
                        //         var p = presets[sel];
                        //         var chosen = String(hex).toLowerCase();
                        //         var themeHex = String(ui.theme.accentColor).toLowerCase();
                        //         // Only store a custom color when it differs from the default accent
                        //         if (chosen === themeHex) {
                        //             try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
                        //         } else {
                        //             p.backgroundColor = hex;
                        //         }
                        //         notifyPresetsMutated();
                        //         savePresetsToSettings();
                        //         refreshPresetsListModel();
                        //     }
                        //     dlg.close();
                        //     dlg.destroy();
                        // });
                        // dlg.closed.connect(function() { dlg.destroy(); });
                        // dlg.open();

                        popupView.toggleOpened()
                    }

                    StyledPopupView {
                        id: popupView
                        contentWidth: layout.childrenRect.width
                        contentHeight: layout.childrenRect.height

                        Row {
                            id: layout
                            spacing: 10
                            width: 30

                            FlatButton {
                                property color swatch: isDarkTheme ? "#F25555" : "#F28585"
                                normalColor: swatch
                                hoverHitColor: swatch
                                width: parent.width

                                onClicked: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                                    if (sel >= 0 && sel < presets.length) {
                                        var p = presets[sel];
                                        var chosen = String(swatch).toLowerCase();
                                        var themeHex = String(ui.theme.accentColor).toLowerCase();

                                        // If same as theme accent, clear custom override
                                        if (chosen === themeHex) {
                                            try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
                                        } else {
                                            p.backgroundColor = swatch;
                                        }

                                        notifyPresetsMutated();
                                        savePresetsToSettings();
                                        refreshPresetsListModel();
                                    }
                                    popupView.close();
                                }
                            }

                            FlatButton {
                                property color swatch: isDarkTheme ? "#E1720B" : "#EDB17A"
                                normalColor: swatch
                                hoverHitColor: swatch
                                width: parent.width

                                onClicked: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                                    if (sel >= 0 && sel < presets.length) {
                                        var p = presets[sel];
                                        var chosen = String(swatch).toLowerCase();
                                        var themeHex = String(ui.theme.accentColor).toLowerCase();

                                        // If same as theme accent, clear custom override
                                        if (chosen === themeHex) {
                                            try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
                                        } else {
                                            p.backgroundColor = swatch;
                                        }

                                        notifyPresetsMutated();
                                        savePresetsToSettings();
                                        refreshPresetsListModel();
                                    }
                                    popupView.close();
                                }
                            }

                            FlatButton {
                                property color swatch: isDarkTheme ? "#AC8C1A" : "#E0CC87"
                                normalColor: swatch
                                hoverHitColor: swatch
                                width: parent.width

                                onClicked: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                                    if (sel >= 0 && sel < presets.length) {
                                        var p = presets[sel];
                                        var chosen = String(swatch).toLowerCase();
                                        var themeHex = String(ui.theme.accentColor).toLowerCase();

                                        // If same as theme accent, clear custom override
                                        if (chosen === themeHex) {
                                            try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
                                        } else {
                                            p.backgroundColor = swatch;
                                        }

                                        notifyPresetsMutated();
                                        savePresetsToSettings();
                                        refreshPresetsListModel();
                                    }
                                    popupView.close();
                                }
                            }

                            FlatButton {
                                property color swatch: isDarkTheme ? "#27A341" : "#8BC9C5"
                                normalColor: swatch
                                hoverHitColor: swatch
                                width: parent.width

                                onClicked: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                                    if (sel >= 0 && sel < presets.length) {
                                        var p = presets[sel];
                                        var chosen = String(swatch).toLowerCase();
                                        var themeHex = String(ui.theme.accentColor).toLowerCase();

                                        // If same as theme accent, clear custom override
                                        if (chosen === themeHex) {
                                            try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
                                        } else {
                                            p.backgroundColor = swatch;
                                        }

                                        notifyPresetsMutated();
                                        savePresetsToSettings();
                                        refreshPresetsListModel();
                                    }
                                    popupView.close();
                                }
                            }

                            FlatButton {
                                property color swatch: isDarkTheme ? "#2093FE" : "#70AFEA"
                                normalColor: swatch
                                hoverHitColor: swatch
                                width: parent.width

                                onClicked: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                                    if (sel >= 0 && sel < presets.length) {
                                        var p = presets[sel];
                                        var chosen = String(swatch).toLowerCase();
                                        var themeHex = String(ui.theme.accentColor).toLowerCase();

                                        // If same as theme accent, clear custom override
                                        if (chosen === themeHex) {
                                            try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
                                        } else {
                                            p.backgroundColor = swatch;
                                        }

                                        notifyPresetsMutated();
                                        savePresetsToSettings();
                                        refreshPresetsListModel();
                                    }
                                    popupView.close();
                                }
                            }

                            FlatButton {
                                property color swatch: isDarkTheme ? "#926BFF" : "#A09EEF"
                                normalColor: swatch
                                hoverHitColor: swatch
                                width: parent.width

                                onClicked: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                                    if (sel >= 0 && sel < presets.length) {
                                        var p = presets[sel];
                                        var chosen = String(swatch).toLowerCase();
                                        var themeHex = String(ui.theme.accentColor).toLowerCase();

                                        // If same as theme accent, clear custom override
                                        if (chosen === themeHex) {
                                            try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
                                        } else {
                                            p.backgroundColor = swatch;
                                        }

                                        notifyPresetsMutated();
                                        savePresetsToSettings();
                                        refreshPresetsListModel();
                                    }
                                    popupView.close();
                                }
                            }

                            FlatButton {
                                property color swatch: isDarkTheme ? "#E454C4" : "#DBA0C7"
                                normalColor: swatch
                                hoverHitColor: swatch
                                width: parent.width

                                onClicked: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                                    if (sel >= 0 && sel < presets.length) {
                                        var p = presets[sel];
                                        var chosen = String(swatch).toLowerCase();
                                        var themeHex = String(ui.theme.accentColor).toLowerCase();

                                        // If same as theme accent, clear custom override
                                        if (chosen === themeHex) {
                                            try { delete p.backgroundColor; } catch(e) { p.backgroundColor = ""; }
                                        } else {
                                            p.backgroundColor = swatch;
                                        }

                                        notifyPresetsMutated();
                                        savePresetsToSettings();
                                        refreshPresetsListModel();
                                    }
                                    popupView.close();
                                }
                            }

                            // --- Clear Custom Color Button ---
                            FlatButton {
                                id: clearColorBtn
                                icon: IconCode.DELETE_TANK
                                width: parent.width
                                // Only enabled if the current preset HAS a custom backgroundColor
                                enabled: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
                                        return false;
                                    var p = presets[uiRef.selectedIndex];
                                    return !!(p.backgroundColor && String(p.backgroundColor).length);
                                }

                                onClicked: {
                                    var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                    var sel = (uiRef && uiRef.selectedIndex >= 0) ? uiRef.selectedIndex : -1;
                                    if (sel >= 0 && sel < presets.length) {
                                        var p = presets[sel];
                                        // Remove the custom color and revert to theme accent
                                        try { delete p.backgroundColor; }
                                        catch(e) { p.backgroundColor = ""; }

                                        notifyPresetsMutated();
                                        savePresetsToSettings();
                                        refreshPresetsListModel();
                                    }
                                    popupView.close();
                                }
                            }

                        }
                    }
                }

                FlatButton {
                    id: copyPresetBtn
                    icon: IconCode.COPY
                    enabled: root.canCopyCurrentPreset()
                    // toolTip: qsTr("Copy staves and note rows from current preset")
                    onClicked: {
                        root.copyCurrentPresetToClipboard()
                    }
                }

                FlatButton {
                    id: pastePresetBtn
                    icon: IconCode.PASTE
                    enabled: root.canPasteIntoCurrentPreset()
                    // toolTip: qsTr("Paste copied staves and note rows into this preset (only when empty)")
                    onClicked: {
                        root.pasteClipboardIntoCurrentPreset()
                    }
                }

                // Delete selected (with confirmation)
                FlatButton {
                    icon: IconCode.DELETE_TANK
                    enabled: (allPresetsModel.count > 0)
                    onClicked: {
                        if (rootUI.selectedIndex >= 0 && rootUI.selectedIndex < allPresetsModel.count) {
                            const n = allPresetsModel.get(rootUI.selectedIndex).name;
                            // Create a fresh dialog for this request, parented to the window
                            var parentObj = orchestratorWin ? orchestratorWin : root;
                            var dlg = confirmDeleteComponent.createObject(parentObj, {
                                                                              presetIndex: rootUI.selectedIndex,
                                                                              messageText: qsTr("Do you really want to delete %1?").arg(n)
                                                                          });
                        }
                    }
                }

                // Spacer to push any future controls to top
                Item { Layout.fillHeight: true }
            }

            ColumnLayout {
                id: settingsUI
                // Keep the left panel at the base width and anchor it to the left,
                // so widening the host window does not stretch this column.
                anchors.left: settingsTools.right
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: 5
                anchors.topMargin: 12
                anchors.rightMargin: 12
                anchors.bottomMargin: 12
                spacing: 10

                // RowLayout {
                //     Layout.fillWidth: true
                //     Layout.alignment: Qt.AlignTop
                //     spacing: 8

                //Layout.leftMargin:  rootUI.panelSidePadding
                // Layout.leftMargin: presetScroll.rightPadding + rootUI.iconExtraRightMargin

                // Add preset (placeholder)

                // Item { Layout.fillWidth: true }


                // }

                // --- Preset title (editable) and Save button (aligned with note buttons) ---
                RowLayout {
                    id: presetHeaderRow
                    Layout.fillWidth: true
                    // Match the column spacing used below so left/right columns align perfectly
                    spacing: listAndButtonsRow.spacing

                    Layout.fillHeight: false
                    Layout.alignment: Qt.AlignTop

                    // LEFT HEADER COLUMN: same width as the staff list (stavesBox)
                    Item {
                        id: presetTitleWrap
                        width: stavesBox.width
                        height: presetSaveButton.height

                        TextField {
                            id: presetTitleField
                            anchors.fill: parent
                            placeholderText: qsTr("Preset name")
                            text: qsTr("New Preset")
                            font.bold: true
                            selectByMouse: true
                            width: 200
                            leftPadding: 10

                            // Theme
                            color: ui.theme.fontPrimaryColor
                            selectionColor: Utils.colorWithAlpha(ui.theme.accentColor, ui.theme.accentOpacityNormal)
                            selectedTextColor: ui.theme.fontPrimaryColor
                            placeholderTextColor: Utils.colorWithAlpha(ui.theme.fontPrimaryColor, 0.3)

                            // Neutral border when unfocused; accent only when focused
                            background: Rectangle {
                                radius: 3
                                color: ui.theme.textFieldColor
                                border.width: 1
                                border.color: presetTitleField.activeFocus ? ui.theme.accentColor : ui.theme.strokeColor
                            }

                            onAccepted: {
                                console.log("[Orchestrator] Preset title accepted:", presetTitleField.text)
                            }
                            // Default caret position at the beginning on first render
                            Component.onCompleted: {
                                cursorPosition = 0
                                deselect()
                            }
                        }

                        // Stretch any extra space while preserving the two fixed-width columns above
                        Item { Layout.fillWidth: true }
                    }
                }

                // --- Sprint 1: Staves list row (ported from Keyswitch Creator) ---
                // Keyboard handling at the container level: treat staves list as the focus target
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function (event) {
                    // Only act when the staves panel has focus (list or its scrollview)
                    var stavesFocused = (staffList && staffList.activeFocus) || (stavesScroll && stavesScroll.activeFocus)
                    if (!stavesFocused) return

                    var isShift = !!(event.modifiers & Qt.ShiftModifier)
                    var isCtrl = !!(event.modifiers & Qt.ControlModifier)
                    var isCmd  = !!(event.modifiers & Qt.MetaModifier)

                    // Ctrl/Cmd + A -> select all staves
                    if ((isCtrl || isCmd) && event.key === Qt.Key_A) {
                        selectAll()
                        if (staffList.currentIndex < 0 && staffListModel.count > 0)
                            staffList.currentIndex = 0
                        event.accepted = true
                        return
                    }

                    // Shift + Up/Down -> extend selection
                    if (isShift && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
                        var idx = staffList.currentIndex >= 0 ? staffList.currentIndex : 0
                        if (event.key === Qt.Key_Up)   idx = Math.max(0, idx - 1)
                        if (event.key === Qt.Key_Down) idx = Math.min(staffListModel.count - 1, idx + 1)
                        selectRange(idx)
                        staffList.currentIndex = idx
                        event.accepted = true
                        return
                    }
                }

                // Safety-net shortcuts (Qt.WindowShortcut) in case focus is temporarily elsewhere
                Shortcut {
                    id: scSelectAllStaves
                    context: Qt.WindowShortcut
                    enabled: (staffListModel.count > 0)
                    sequences: [ "Meta+A", "Ctrl+A" ]
                    onActivated: {
                        selectAll()
                        if (staffList.currentIndex < 0 && staffListModel.count > 0)
                            staffList.currentIndex = 0
                    }
                }
                Shortcut {
                    id: scShiftUp
                    context: Qt.WindowShortcut
                    enabled: (staffListModel.count > 0)
                    sequences: [ "Shift+Up" ]
                    onActivated: {
                        var cur = (staffList.currentIndex >= 0) ? staffList.currentIndex : 0
                        var next = Math.max(0, cur - 1)
                        if (lastAnchorIndex < 0) lastAnchorIndex = cur
                        selectRange(next)
                        staffList.currentIndex = next
                    }
                }
                Shortcut {
                    id: scShiftDown
                    context: Qt.WindowShortcut
                    enabled: (staffListModel.count > 0)
                    sequences: [ "Shift+Down" ]
                    onActivated: {
                        var cur = (staffList.currentIndex >= 0) ? staffList.currentIndex : 0
                        var last = Math.max(0, staffListModel.count - 1)
                        var next = Math.min(last, cur + 1)
                        if (lastAnchorIndex < 0) lastAnchorIndex = cur
                        selectRange(next)
                        staffList.currentIndex = next
                    }
                }

                // Visual list + note buttons (side-by-side)
                RowLayout {
                    id: listAndButtonsRow

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: settingsUI.anchors.leftMargin

                    // --- Left: Staves list (fixed width like KSC) ---
                    GroupBox {
                        id: stavesBox
                        Layout.alignment: Qt.AlignTop
                        // Do NOT stretch to fill the available height; cap at content height instead
                        // (leaves the right note column free to keep growing with the window)
                        Layout.fillHeight: true

                        // Exact same width policy as before
                        Layout.preferredWidth: 200
                        Layout.maximumWidth: 200
                        Layout.minimumWidth: 200

                        // Height policy:
                        // - Maximum height equals the total list content (stops after the last staff)
                        // - Preferred height is the smaller of contentHeight and the available settingsUI height
                        //   so we still behave nicely when the list is taller than the window.
                        Layout.maximumHeight: staffList ? staffList.contentHeight : 0
                        Layout.preferredHeight: Math.min(
                                                    staffList ? staffList.contentHeight : 0,
                                                    settingsUI.height - 24 /* leave the panel's margins/spacing */
                                                    )

                        padding: 0
                        background: Rectangle { color: ui.theme.textFieldColor }
                        ScrollView {
                            id: stavesScroll
                            anchors.fill: parent
                            focus: true
                            Keys.forwardTo: [staffList] // Ensure arrow keys reach the list

                            ListView {
                                id: staffList
                                activeFocusOnTab: true
                                clip: true
                                focus: true
                                model: staffListModel
                                height: orchestratorWin.height - 10
                                spacing: 2

                                delegate: ItemDelegate {
                                    id: rowDelegate
                                    width: ListView.view.width

                                    background: Rectangle {
                                        anchors.fill: parent
                                        color: isRowSelected(index) ? ui.theme.accentColor : "transparent"
                                        opacity: isRowSelected(index) ? 0.65 : 1.0
                                        radius: 3
                                    }

                                    // Accent bar for staff with any active note rows
                                    Rectangle {
                                        id: activeNoteBar
                                        anchors {
                                            left: parent.left
                                            top: parent.top
                                            bottom: parent.bottom
                                        }
                                        width: 3
                                        radius: 1
                                        color: ui.theme.accentColor
                                        visible: {
                                            var p = orchestratorWin && root.presets[rootUI.selectedIndex];
                                            if (!p || !p.noteRowsByStaff)
                                                return false;

                                            var sid = model.idx;
                                            var rows = p.noteRowsByStaff[sid];
                                            if (!rows)
                                                return false;

                                            for (var i = 0; i < rows.length; i++)
                                                if (rows[i].active) return true;

                                            return false;
                                        }
                                        z: 10
                                    }

                                    leftPadding: 10
                                    contentItem: Text {
                                        color: ui.theme.fontPrimaryColor
                                        font.bold: isRowSelected(index)
                                        elide: Text.ElideRight
                                        text: cleanName(model.name)
                                        textFormat: Text.PlainText
                                        verticalAlignment: Text.AlignVCenter
                                    }

                                    MouseArea {
                                        acceptedButtons: Qt.LeftButton
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: function (mouse) {
                                            var idx = index
                                            var ctrlOrCmd = (mouse.modifiers & Qt.ControlModifier) || (mouse.modifiers & Qt.MetaModifier)
                                            var isShift = (mouse.modifiers & Qt.ShiftModifier)

                                            if (isShift)
                                                selectRange(idx)
                                            else if (ctrlOrCmd)
                                                toggleRow(idx)
                                            else
                                                selectSingle(idx)

                                            staffList.currentIndex = idx
                                            staffList.forceActiveFocus()

                                            // When user selects a staff, load that staff’s note rows
                                            if (rootUI.selectedIndex >= 0)
                                                applyPresetToUI(rootUI.selectedIndex, { preserveStaffSelection: true })
                                        }
                                    }
                                }

                                // (existing key handling unchanged)
                                Keys.onPressed: function (event) {
                                    const isCmd = !!(event.modifiers & Qt.MetaModifier)
                                    const isCtrl = !!(event.modifiers & Qt.ControlModifier)
                                    const isShift = !!(event.modifiers & Qt.ShiftModifier)
                                    if ((isCmd || isCtrl) && event.key === Qt.Key_A) {
                                        selectAll()
                                        if (staffList.currentIndex < 0 && staffListModel.count > 0)
                                            staffList.currentIndex = 0
                                        event.accepted = true
                                        return
                                    }
                                    if (event.key === Qt.Key_Up) {
                                        var idx = Math.max(0, staffList.currentIndex - 1)
                                        if (isShift) selectRange(idx); else selectSingle(idx)
                                        staffList.currentIndex = idx

                                        // keep current staff selection; just reload rows for the new focus
                                        if (rootUI.selectedIndex >= 0)
                                            applyPresetToUI(rootUI.selectedIndex, { preserveStaffSelection: true })

                                        event.accepted = true
                                        return
                                    }
                                    if (event.key === Qt.Key_Down) {
                                        var idx2 = Math.min(staffListModel.count - 1, staffList.currentIndex + 1)
                                        if (isShift) selectRange(idx2); else selectSingle(idx2)
                                        staffList.currentIndex = idx2

                                        // keep current staff selection; just reload rows for the new focus
                                        if (rootUI.selectedIndex >= 0)
                                            applyPresetToUI(rootUI.selectedIndex, { preserveStaffSelection: true })

                                        event.accepted = true
                                        return
                                    }
                                }
                                Keys.onShortcutOverride: function (event) {
                                    const isShift = !!(event.modifiers & Qt.ShiftModifier)
                                    const isCmd   = !!(event.modifiers & Qt.MetaModifier)
                                    const isCtrl  = !!(event.modifiers & Qt.ControlModifier)
                                    const isA     = (event.key === Qt.Key_A)
                                    const shUp    = isShift && (event.key === Qt.Key_Up)
                                    const shDown  = isShift && (event.key === Qt.Key_Down)
                                    if (shUp || shDown || (isA && (isCmd || isCtrl))) {
                                        event.accepted = true
                                    }
                                }
                            }
                        }
                    }

                    // --- Right: 8-note button column (MULTI-SELECT like staves list) ---
                    Item {
                        id: noteButtonsPane
                        Layout.alignment: Qt.AlignTop
                        Layout.fillHeight: true

                        visible: true

                        // Button column is 180px wide; gap equals listAndButtonsRow.spacing;
                        // dropdown gets a measured minimum width (ddMinWidth) so "+24" and the triangle fit.
                        // (Pane locks to that sum so columns align cleanly.)
                        Layout.preferredWidth: 120 + listAndButtonsRow.spacing + ddMinWidth
                        Layout.maximumWidth: 120 + listAndButtonsRow.spacing + ddMinWidth
                        Layout.minimumWidth: 120 + listAndButtonsRow.spacing + ddMinWidth

                        // --- Dropdown width probe (measure "+24" using the actual StyledDropdown font) ---
                        StyledDropdown { id: _ddProbe; visible: false } // font may be undefined early
                        FontMetrics {
                            id: _ddFM
                            font: (_ddProbe && _ddProbe.font) ? _ddProbe.font : Qt.font({})
                        }

                        //  text width of "+24" + indicator allowance
                        property int ddMinWidth: Math.ceil(_ddFM.advanceWidth("+24")) + 42

                        // ---------- Multi-select state & helpers (pattern matches staves list) ----------
                        // Map: row index -> true when selected
                        property var selectedNotes: ({})
                        // Anchor for Shift-range operations
                        property int lastAnchorNoteIndex: -1

                        function clearNoteSelection() {
                            selectedNotes = ({})
                            root.scheduleLiveCommit()
                        }
                        // ---- Voice selection state (one voice per row; independent per row) ----
                        // Map: row index -> 1|2|3|4 (selected voice), or undefined for none
                        property var voiceByRow: ({})
                        property var pitchIndexByRow: ({})

                        function setVoiceForRow(rowIndex, v) {
                            // Disallow "no voice": clicking the same voice keeps it selected.
                            // Coerce v to 1..4; default to 1 if anything unexpected comes in.
                            var vv = (v === 1 || v === 2 || v === 3 || v === 4) ? v : 1
                            var m = Object.assign({}, voiceByRow)
                            m[rowIndex] = vv
                            voiceByRow = m

                            // Live-commit after voice change
                            root.scheduleLiveCommit()
                        }
                        // Default every row to Voice 1 so it appears active initially
                        // Map: row index -> dropdown index (0..48), 24 = "--" (0 semitones)
                        Component.onCompleted: {
                            var m = {}
                            for (var i = 0; i < noteButtonsModel.count; ++i) {
                                m[i] = 24  // default 0 semitones
                            }
                            pitchIndexByRow = m
                            // (voiceByRow initialization stays intact below)
                        }
                        function isNoteSelected(i) {
                            return !!selectedNotes[i]
                        }
                        function setNoteSelected(i, on) {
                            var ns = Object.assign({}, selectedNotes)
                            if (on) ns[i] = true
                            else delete ns[i]
                            selectedNotes = ns
                            // Live-commit after this change
                            root.scheduleLiveCommit()
                        }
                        function toggleNote(i) {
                            setNoteSelected(i, !isNoteSelected(i))
                            lastAnchorNoteIndex = i
                        }
                        function selectSingleNote(i) {
                            clearNoteSelection()
                            setNoteSelected(i, true)
                            lastAnchorNoteIndex = i
                            noteButtonsView.currentIndex = i
                        }
                        function selectRangeNote(i) {
                            if (lastAnchorNoteIndex < 0) { selectSingleNote(i); return }
                            var a = Math.min(lastAnchorNoteIndex, i)
                            var b = Math.max(lastAnchorNoteIndex, i)
                            clearNoteSelection()
                            for (var r = a; r <= b; ++r) setNoteSelected(r, true)
                            noteButtonsView.currentIndex = i
                        }
                        function selectAllNotes() {
                            clearNoteSelection()
                            for (var r = 0; r < noteButtonsModel.count; ++r) setNoteSelected(r, true)
                            if (noteButtonsView.currentIndex < 0 && noteButtonsModel.count > 0)
                                noteButtonsView.currentIndex = 0
                            // setNoteSelected already schedules commit; no extra call needed here
                        }

                        // Height probe for “normal MuseScore button height”
                        FlatButton { id: _btnProbe; text: qsTr("Probe"); visible: false }

                        // Model for buttons (top to bottom)
                        ListModel {
                            id: noteButtonsModel
                            ListElement { name: "Top note" }
                            ListElement { name: "Seventh note" }
                            ListElement { name: "Sixth note" }
                            ListElement { name: "Fifth note" }
                            ListElement { name: "Fourth note" }
                            ListElement { name: "Third note" }
                            ListElement { name: "Second note" }
                            ListElement { name: "Bottom note" }

                            // If rows are ever added later, default them to Voice 1
                            onCountChanged: {
                                var m = Object.assign({}, noteButtonsPane.voiceByRow)
                                for (var i = 0; i < noteButtonsModel.count; ++i) {
                                    if (m[i] === undefined) m[i] = 1
                                }
                                noteButtonsPane.voiceByRow = m
                            }
                        }

                        // Window-scoped safety nets (parity with staves list)
                        Shortcut {
                            id: nbSelectAll
                            context: Qt.WindowShortcut
                            enabled: noteButtonsView && (noteButtonsView.activeFocus || noteButtonsPane.activeFocus)
                            sequences: [ "Meta+A", "Ctrl+A" ]
                            onActivated: selectAllNotes()
                        }
                        Shortcut {
                            id: nbShiftUp
                            context: Qt.WindowShortcut
                            enabled: noteButtonsView && (noteButtonsView.activeFocus || noteButtonsPane.activeFocus)
                            sequences: [ "Shift+Up" ]
                            onActivated: {
                                var cur = (noteButtonsView.currentIndex >= 0) ? noteButtonsView.currentIndex : 0
                                var next = Math.max(0, cur - 1)
                                if (lastAnchorNoteIndex < 0) lastAnchorNoteIndex = cur
                                selectRangeNote(next)
                            }
                        }
                        Shortcut {
                            id: nbShiftDown
                            context: Qt.WindowShortcut
                            enabled: noteButtonsView && (noteButtonsView.activeFocus || noteButtonsPane.activeFocus)
                            sequences: [ "Shift+Down" ]
                            onActivated: {
                                var cur = (noteButtonsView.currentIndex >= 0) ? noteButtonsView.currentIndex : 0
                                var last = Math.max(0, noteButtonsModel.count - 1)
                                var next = Math.min(last, cur + 1)
                                if (lastAnchorNoteIndex < 0) lastAnchorNoteIndex = cur
                                selectRangeNote(next)
                            }
                        }

                        // Non-interactive list; each row is a FlatButton delegate
                        ListView {
                            id: noteButtonsView
                            anchors.top: parent.top
                            anchors.left: parent.left
                            width: parent.width
                            interactive: false
                            spacing: 8
                            model: noteButtonsModel
                            clip: false
                            focus: true
                            currentIndex: 0

                            delegate: Item {
                                // Keep the same measured row height as before
                                width: noteButtonsView.width
                                height: _btnProbe.implicitHeight

                                Row {
                                    id: rowContent
                                    anchors {
                                        left: parent.left
                                        leftMargin: 5   // keep external gap equal to RowLayout spacing
                                        verticalCenter: parent.verticalCenter
                                    }
                                    spacing: listAndButtonsRow.spacing

                                    // Left: the note button (multi-select accent)
                                    FlatButton {
                                        id: noteBtn
                                        width: 120
                                        height: _btnProbe.implicitHeight
                                        text: model.name
                                        // Multi-select: accent when selected
                                        property bool isActive: !!noteButtonsPane.selectedNotes[index]
                                        accentButton: isActive
                                        transparent: false

                                        // --- Accent strip INSIDE the button, at its left edge ---
                                        Rectangle {
                                            id: noteActiveBar
                                            anchors {
                                                left: parent.left
                                                top: parent.top
                                                bottom: parent.bottom
                                            }
                                            width: 3
                                            radius: 1
                                            color: ui.theme.accentColor
                                            // Visible if ANY staff in the selected preset has this note-row active
                                            visible: {
                                                var p = orchestratorWin && root.presets[rootUI.selectedIndex];
                                                if (!p || !p.noteRowsByStaff) return false;

                                                for (var sIdKey in p.noteRowsByStaff) {
                                                    if (!p.noteRowsByStaff.hasOwnProperty(sIdKey)) continue;
                                                    var rows = p.noteRowsByStaff[sIdKey] || [];
                                                    if (index >= 0 && index < rows.length && rows[index] && rows[index].active)
                                                        return true;
                                                }
                                                return false;
                                            }
                                            z: 1
                                        }

                                        onClicked: function (mouse) {
                                            var ctrlOrCmd = (mouse.modifiers & Qt.ControlModifier)
                                                    || (mouse.modifiers & Qt.MetaModifier)
                                            var isShift = (mouse.modifiers & Qt.ShiftModifier)
                                            if (isShift) {
                                                // Shift = extend selection to range (unchanged)
                                                noteButtonsPane.selectRangeNote(index)
                                            } else if (ctrlOrCmd) {
                                                // Cmd/Ctrl = explicit toggle (unchanged)
                                                noteButtonsPane.toggleNote(index)
                                            } else {
                                                // Plain click = toggle on/off (NEW)
                                                noteButtonsPane.toggleNote(index)
                                            }
                                            // Keep keyboard focus/anchor behavior the same
                                            noteButtonsView.currentIndex = index
                                        }
                                    }

                                    // Right: chromatic pitch transformer dropdown (+24…--…-24), revealed only when active
                                    Item {
                                        id: ddWrap
                                        height: _btnProbe.implicitHeight
                                        // Show when the note is active; animate the width/opacity for a smooth reveal
                                        width: noteBtn.isActive ? noteButtonsPane.ddMinWidth : 0
                                        opacity: noteBtn.isActive ? 1.0 : 0.0
                                        enabled: noteBtn.isActive
                                        clip: true
                                        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                                        Behavior on opacity{ NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                                        StyledDropdown {
                                            id: pitchShift
                                            anchors.fill: parent
                                            // +24..+1, -- (0), -1..-24
                                            model: (function () {
                                                var items = [], i
                                                for (i = 24; i >= 1; --i) items.push({ text: "+" + i, value: i })
                                                items.push({ text: "--", value: 0 })
                                                for (i = -1; i >= -24; --i) items.push({ text: "" + i, value: i })
                                                return items
                                            })()
                                            currentIndex: (noteButtonsPane.pitchIndexByRow[index] !== undefined)
                                                          ? noteButtonsPane.pitchIndexByRow[index] : 24
                                            onActivated: function(ix, value) {
                                                var m = Object.assign({}, noteButtonsPane.pitchIndexByRow)
                                                m[index] = ix
                                                noteButtonsPane.pitchIndexByRow = m
                                                // Live-commit after pitch change
                                                root.scheduleLiveCommit()
                                            }
                                        }
                                    }

                                    // Voice toggles — revealed only when the note is active
                                    Item {
                                        id: voiceWrap
                                        height: _btnProbe.implicitHeight
                                        // Grow to the row's natural width when active
                                        width: noteBtn.isActive ? voiceRow.implicitWidth : 0
                                        opacity: noteBtn.isActive ? 1.0 : 0.0
                                        enabled: noteBtn.isActive
                                        clip: true
                                        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                                        Behavior on opacity{ NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }

                                        // Voice toggles as a tight group (edges touching)
                                        Row {
                                            id: voiceRow
                                            spacing: 0 // edges touching between voice buttons
                                            FlatButton {
                                                id: voice1Btn
                                                icon: IconCode.VOICE_1
                                                property bool selected: (noteButtonsPane.voiceByRow[index] === 1)
                                                accentButton: selected
                                                transparent: !selected
                                                onClicked: noteButtonsPane.setVoiceForRow(index, 1)
                                            }
                                            FlatButton {
                                                id: voice2Btn
                                                icon: IconCode.VOICE_2
                                                property bool selected: (noteButtonsPane.voiceByRow[index] === 2)
                                                accentButton: selected
                                                transparent: !selected
                                                onClicked: noteButtonsPane.setVoiceForRow(index, 2)
                                            }
                                            FlatButton {
                                                id: voice3Btn
                                                icon: IconCode.VOICE_3
                                                property bool selected: (noteButtonsPane.voiceByRow[index] === 3)
                                                accentButton: selected
                                                transparent: !selected
                                                onClicked: noteButtonsPane.setVoiceForRow(index, 3)
                                            }
                                            FlatButton {
                                                id: voice4Btn
                                                icon: IconCode.VOICE_4
                                                property bool selected: (noteButtonsPane.voiceByRow[index] === 4)
                                                accentButton: selected
                                                transparent: !selected
                                                onClicked: noteButtonsPane.setVoiceForRow(index, 4)
                                            }
                                        }
                                    }
                                }
                            }

                            // Let the view size itself to content
                            implicitHeight: (count > 0)
                                            ? (count * (_btnProbe.implicitHeight) + (count - 1) * spacing)
                                            : 0

                            // Keyboard parity with staves list
                            Keys.onPressed: function (event) {
                                const isCmd  = !!(event.modifiers & Qt.MetaModifier)
                                const isCtrl = !!(event.modifiers & Qt.ControlModifier)
                                const isShift = !!(event.modifiers & Qt.ShiftModifier)

                                // Cmd/Ctrl + A = select all
                                if ((isCmd || isCtrl) && event.key === Qt.Key_A) {
                                    selectAllNotes()
                                    if (noteButtonsView.currentIndex < 0 && noteButtonsModel.count > 0)
                                        noteButtonsView.currentIndex = 0
                                    event.accepted = true
                                    return
                                }

                                if (event.key === Qt.Key_Up) {
                                    var idx = Math.max(0, noteButtonsView.currentIndex - 1)
                                    if (isShift) selectRangeNote(idx); else selectSingleNote(idx)
                                    noteButtonsView.currentIndex = idx
                                    event.accepted = true
                                    return
                                }
                                if (event.key === Qt.Key_Down) {
                                    var idx2 = Math.min(noteButtonsModel.count - 1, noteButtonsView.currentIndex + 1)
                                    if (isShift) selectRangeNote(idx2); else selectSingleNote(idx2)
                                    noteButtonsView.currentIndex = idx2
                                    event.accepted = true
                                    return
                                }
                            }

                            // Keep the chords for this view when focused
                            Keys.onShortcutOverride: function (event) {
                                const isShift = !!(event.modifiers & Qt.ShiftModifier)
                                const isCmd   = !!(event.modifiers & Qt.MetaModifier)
                                const isCtrl  = !!(event.modifiers & Qt.ControlModifier)
                                const isA     = (event.key === Qt.Key_A)
                                const shUp    = isShift && (event.key === Qt.Key_Up)
                                const shDown  = isShift && (event.key === Qt.Key_Down)
                                if (shUp || shDown || (isA && (isCmd || isCtrl))) {
                                    event.accepted = true
                                }
                            }




                        }

                        // ---------------------- Notation Elements to Copy --------------------------
                        Item {
                            id: notationElementsWrapper

                            anchors {
                                left: parent.left
                                right: parent.right
                                top: noteButtonsView.bottom
                                topMargin: 8
                                bottom: parent.bottom
                                // bottomMargin: 10   // faux bottom margin to align with staves list
                            }

                            clip: true

                            // Convenience: current preset object or null
                            function currentPreset() {
                                var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null
                                if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length) return null
                                return presets[uiRef.selectedIndex]
                            }

                            // Write-through update helpers
                            function toggleKey(key, on) {
                                var p = currentPreset()
                                if (!p) return
                                if (!p.notationFilter) p.notationFilter = defaultNotationFilter()
                                p.notationFilter[key] = !!on
                                syncNotationAll(p.notationFilter)
                                notifyPresetsMutated()
                                savePresetsToSettings()
                            }

                            function toggleKeyInverse(key) {
                                var p = currentPreset()
                                if (!p) return
                                if (!p.notationFilter) p.notationFilter = defaultNotationFilter()
                                var cur = !!p.notationFilter[key]
                                toggleKey(key, !cur)    // reuse your write-through, bookkeeping, and save
                            }

                            function setAllChecked(on) {
                                var p = currentPreset()
                                if (!p) return
                                if (!p.notationFilter) p.notationFilter = defaultNotationFilter()
                                setNotationAll(p.notationFilter, !!on)
                                notifyPresetsMutated()
                                savePresetsToSettings()
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                // anchors.bottomMargin: 10
                                anchors.leftMargin: 0
                                anchors.rightMargin: 0
                                anchors.topMargin: 0
                                anchors.top: notationElementsWrapper.top
                                spacing: 6

                                Label {
                                    text: qsTr("Notation Elements")
                                    font.bold: true
                                    color: ui.theme.fontPrimaryColor
                                    // Layout.topMargin: 10
                                    Layout.leftMargin: 5
                                }

                                ColumnLayout {
                                    // Fill the wrapper Item and leave a 10px faux margin at the bottom,
                                    // matching the staves ListView’s (height: orchestratorWin.height - 10).
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 5
                                    spacing: 6

                                    // Master 'All' checkbox (Muse.UiComponents)
                                    // Visual tri-state via isIndeterminate; click cycles Checked<->Unchecked
                                    CheckBox {
                                        id: allBox
                                        text: qsTr("All")

                                        // All is 'checked' only when every child is on
                                        checked: {
                                            var p = notationElementsWrapper.currentPreset()
                                            return p && p.notationFilter ? (notationAllState(p.notationFilter) === Qt.Checked) : true
                                        }

                                        // Show the dash when some but not all items are selected
                                        isIndeterminate: {
                                            var p = notationElementsWrapper.currentPreset()
                                            return p && p.notationFilter ? (notationAllState(p.notationFilter) === Qt.PartiallyChecked) : false
                                        }

                                        // Clicking the parent toggles "all on" when indeterminate/unchecked, or "all off" when checked
                                        onClicked: {
                                            var p = notationElementsWrapper.currentPreset()
                                            if (!p || !p.notationFilter) return
                                            var st = notationAllState(p.notationFilter)  // Qt.Unchecked / Qt.PartiallyChecked / Qt.Checked
                                            var wantOn = (st !== Qt.Checked)             // partial/unchecked -> turn everything ON; checked -> OFF
                                            notationElementsWrapper.setAllChecked(wantOn)
                                        }
                                    }

                                    // Child rows (bind directly to the selected preset's notationFilter keys)
                                    CheckBox {
                                        text: qsTr("Dynamics")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.dynamics)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("dynamics")
                                    }
                                    CheckBox {
                                        text: qsTr("Hairpins")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.hairpins)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("hairpins")
                                    }
                                    CheckBox {
                                        text: qsTr("Fingerings")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.fingerings)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("fingerings")
                                    }
                                    CheckBox {
                                        text: qsTr("Lyrics")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.lyrics)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("lyrics")
                                    }
                                    CheckBox {
                                        text: qsTr("Chord symbols")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.chordSymbols)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("chordSymbols")
                                    }
                                    CheckBox {
                                        text: qsTr("Other text")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.otherText)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("otherText")
                                    }
                                    CheckBox {
                                        text: qsTr("Articulations")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.articulations)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("articulations")
                                    }
                                    CheckBox {
                                        text: qsTr("Ornaments")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.ornaments)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("ornaments")
                                    }
                                    CheckBox {
                                        text: qsTr("Slurs")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.slurs)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("slurs")
                                    }
                                    CheckBox {
                                        text: qsTr("Ties")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.ties)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("ties")
                                    }
                                    CheckBox {
                                        text: qsTr("Figured bass")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.figuredBass)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("figuredBass")
                                    }
                                    CheckBox {
                                        text: qsTr("Ottavas")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.ottavas)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("ottavas")
                                    }
                                    CheckBox {
                                        text: qsTr("Pedal lines")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.pedalLines)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("pedalLines")
                                    }
                                    CheckBox {
                                        text: qsTr("Other lines")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.otherLines)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("otherLines")
                                    }
                                    CheckBox {
                                        text: qsTr("Arpeggios")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.arpeggios)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("arpeggios")
                                    }
                                    CheckBox {
                                        text: qsTr("Glissandos")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.glissandos)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("glissandos")
                                    }
                                    CheckBox {
                                        text: qsTr("Fretboard diagrams") // fixed typo
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.fretboardDiagrams)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("fretboardDiagrams")
                                    }
                                    CheckBox {
                                        text: qsTr("Breath marks")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.breathMarks)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("breathMarks")
                                    }
                                    CheckBox {
                                        text: qsTr("Tremolos")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.tremolos)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("tremolos")
                                    }
                                    CheckBox {
                                        text: qsTr("Grace notes")
                                        checked: !!(notationElementsWrapper.currentPreset()
                                                    && notationElementsWrapper.currentPreset().notationFilter
                                                    && notationElementsWrapper.currentPreset().notationFilter.graceNotes)
                                        onClicked: notationElementsWrapper.toggleKeyInverse("graceNotes")
                                    }
                                    Item { Layout.fillHeight: true }
                                }
                            }
                        }
                    }
                }
            }

            Component {
                id: confirmDeleteComponent

                Item {
                    id: dlg
                    anchors.fill: parent
                    z: 99999 // Always stays above plugin UI
                    property int presetIndex: -1
                    property string messageText: ""

                    // --- Dimmed backdrop ---
                    Rectangle {
                        anchors.fill: parent
                        color: "#000"
                        opacity: 0.35
                    }

                    // --- Centered dialog card ---
                    Rectangle {
                        id: card
                        width: 360
                        radius: 6
                        color: ui.theme.backgroundPrimaryColor
                        border.width: 1
                        border.color: ui.theme.strokeColor
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter

                        // NEW: card height based on content
                        height: contentColumn.implicitHeight + 40   // margins * 2

                        Column {
                            id: contentColumn
                            anchors.fill: parent
                            anchors.margins: 20
                            spacing: 16

                            // Title
                            Label {
                                text: qsTr("Delete preset")
                                font.pixelSize: 16
                                font.bold: true
                                color: ui.theme.fontPrimaryColor
                            }

                            // Message text
                            Label {
                                text: dlg.messageText
                                width: parent.width
                                wrapMode: Text.WordWrap
                                color: ui.theme.fontPrimaryColor
                            }

                            // Button row
                            Row {
                                spacing: 10
                                anchors.right: parent.right

                                // CANCEL
                                // FlatButton {
                                //     text: qsTr("Cancel")
                                //     transparent: false
                                //     onClicked: dlg.destroy()
                                // }

                                // NO
                                FlatButton {
                                    text: qsTr("No")
                                    transparent: false
                                    onClicked: dlg.destroy()
                                }

                                // YES (accent)
                                FlatButton {
                                    text: qsTr("Yes")
                                    accentButton: true
                                    transparent: false
                                    onClicked: {
                                        win.pluginRoot.deletePresetAtIndex(dlg.presetIndex)
                                        dlg.destroy()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
