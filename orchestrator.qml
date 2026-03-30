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
    version: "0.1.4"


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

    // Dynamic engine function exports
    property var dynamicAPI: ({
                                  detectDynamics: null,
                                  createDynamic: null,
                                  createHairpin: null,
                                  addDynamicByBeat: null
                              })

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

    property var slurStartByStaff: ({})

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
        var chords = [];
        if (!curScore || !curScore.selection)
            return chords;

        // Range selection
        if (curScore.selection.isRange) {
            // ✅ Convert Segment.tick (Segment object in MS4.7) → numeric ticks
            var startTick = fractionToTicks(curScore.selection.startSegment.tick);
            var endTick = curScore.selection.endSegment
                    ? fractionToTicks(curScore.selection.endSegment.tick)
                    : (
                          curScore.lastSegment
                          ? fractionToTicks(curScore.lastSegment.tick) + 1
                          : startTick
                          );

            var c = curScore.newCursor();
            c.track = srcStaffIdx * 4;
            c.rewindToTick(startTick);

            while (c.segment && c.tick < endTick) {
                var el = c.element;
                if (el && el.type === Element.CHORD && el.noteType === NoteType.NORMAL)
                    chords.push(el);
                if (!c.next())
                    break;
            }
        }

        // List selection
        else {
            for (var i = 0; i < curScore.selection.elements.length; ++i) {
                var el = curScore.selection.elements[i];
                var ch = null;

                if (el && el.type === Element.NOTE && el.parent && el.parent.type === Element.CHORD)
                    ch = el.parent;
                else if (el && el.type === Element.CHORD)
                    ch = el;

                if (!ch) continue;
                if (ch.noteType !== NoteType.NORMAL) continue;
                if (ch.staffIdx === srcStaffIdx)
                    chords.push(ch);
            }

            // deterministic order
            chords.sort(function(a, b) {
                if (a.fraction.lessThan(b.fraction)) return -1;
                if (a.fraction.greaterThan(b.fraction)) return 1;
                return a.track - b.track;
            });
        }

        return chords;
    }

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

    function orchestratorRowsForStaff(_srcStaff) {
        // Always route slurs and notes to ALL active (dstStaff, voice) pairs
        // in the currently selected preset. The source staff is irrelevant.
        const uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!uiRef ||
                uiRef.selectedIndex < 0 ||
                uiRef.selectedIndex >= presets.length)
        {
            return [];
        }

        const p = presets[uiRef.selectedIndex];
        if (!p || !p.noteRowsByStaff) return [];

        const out = [];

        // Scan every staff defined in this preset
        for (let sid in p.noteRowsByStaff) {
            if (!p.noteRowsByStaff.hasOwnProperty(sid))
                continue;

            const rows = p.noteRowsByStaff[sid];
            if (!rows) continue;

            // For each active note-row (0..7), return the destination staff + voice
            for (let i = 0; i < rows.length; ++i) {
                const r = rows[i];
                if (!r || !r.active) continue;

                out.push({
                             dstStaff: parseInt(sid, 10),
                             voice: clampInt(Number(r.voice || 1), 1, 4)
                         });
            }
        }

        return out;
    }

    // Main entry: apply the current preset to the current selection
    function applyCurrentPresetToSelection() {
        if (!curScore || !curScore.selection) return;

        // --- Resolve the selected preset ---
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length) return;
        var p = presets[uiRef.selectedIndex];
        if (!p || !p.noteRowsByStaff) return;

        // --- Notation filter (needed for slurs, ties, articulations, ornaments) ---
        var nf = (p.notationFilter ? p.notationFilter : defaultNotationFilter());

        // ------------------------------------------------------------------------
        // Determine REAL source staff (prefer slur source rather than selection)
        // ------------------------------------------------------------------------
        var srcStaff = -1;

        // First: detect slur-based staff
        if (curScore.spanners && curScore.spanners.length > 0) {
            for (var i = 0; i < curScore.spanners.length; ++i) {
                var s = curScore.spanners[i];
                if (!s) continue;

                var isSlur = false;
                try { if (typeof Element.SLUR !== "undefined" && s.type === Element.SLUR) isSlur = true; } catch(_) {}
                try { if (typeof Element.SLUR_SEGMENT !== "undefined" && s.type === Element.SLUR_SEGMENT) isSlur = true; } catch(_) {}
                if (!isSlur) continue;

                var stf = -1;
                try { if (s.startElement && s.startElement.staffIdx !== undefined) stf = s.startElement.staffIdx; } catch(_) {}
                try { if (stf < 0 && s.track !== undefined) stf = Math.floor(s.track / 4); } catch(_) {}

                if (stf >= 0) { srcStaff = stf; break; }
            }
        }

        // Fallback: first element in selection
        if (srcStaff < 0) {
            if (curScore.selection.isRange) {
                srcStaff = curScore.selection.startStaff;
            } else {
                for (var ii = 0; ii < curScore.selection.elements.length; ++ii) {
                    var el = curScore.selection.elements[ii];
                    var ch = (el && el.parent && el.parent.staffIdx !== undefined) ? el.parent : el;
                    if (ch && ch.staffIdx !== undefined) { srcStaff = ch.staffIdx; break; }
                }
            }
        }

        if (!(srcStaff >= 0)) {
            console.log("[Orchestrator] No sketch staff detected from selection; aborting.");
            return;
        }

        // ------------------------------------------------------------------------
        // Gather source chords
        // ------------------------------------------------------------------------
        var srcChords = collectSourceChordsInSelectionForStaff(srcStaff);
        if (!srcChords.length) return;

        // ------------------------------------------------------------------------
        // PRE-WRITE SLUR DETECTION (your existing working pipeline)
        // ------------------------------------------------------------------------
        let pendingSlurs = [];
        if (nf.slurs && srcChords.length > 0) {
            const firstTick = srcChords[0].parent.tick;
            const lastTick = srcChords[srcChords.length - 1].parent.tick + 1;
            let allow = {};
            allow[srcStaff] = true;

            buildSlurStartMapFromSpanners(firstTick, lastTick, allow);
            pendingSlurs = queueSlursForOrchestration(srcStaff, srcChords);
        }

        console.log("[SLURDBG] pendingSlurs count:", pendingSlurs.length);

        // ------------------------------------------------------------------------
        // NEW: TIE & SYMBOL QUEUES
        // ------------------------------------------------------------------------
        let pendingTies = [];
        let pendingTiesSeen = {};
        let pendingSymbols = [];
        let pendingDynamics = [];
        let pendingHairpins = [];

        // ------------------------------------------------------------------------
        // WRITE PASS (notes + queue ties + queue symbols)
        // ------------------------------------------------------------------------
        curScore.startCmd(qsTr("Orchestrator apply: %1").arg(String(p.name ?? qsTr("Preset"))));

        // Cache a single detectDynamics() snapshot for this whole apply pass
        const dsetAll = detectDynamics(curScore);
        try {
            console.log("[DYNDBG] cached detectDynamics: dynamics=", dsetAll.dynamics.length,
                        "hairpins=", dsetAll.hairpins.length);
        } catch (_) {}

        try {
            for (var ci = 0; ci < srcChords.length; ++ci) {
                var chord = srcChords[ci];
                var frac = chord.fraction;
                var dur = chord.actualDuration;
                var num = (dur && dur.numerator) ? dur.numerator : 1;
                var den = (dur && dur.denominator) ? dur.denominator : 4;

                for (var sidKey in p.noteRowsByStaff) {
                    if (!p.noteRowsByStaff.hasOwnProperty(sidKey)) continue;

                    var tgtStaff = parseInt(sidKey, 10);
                    if (isNaN(tgtStaff) || tgtStaff < 0) continue;

                    var rows = p.noteRowsByStaff[sidKey] || [];
                    var anyActive = false;
                    for (var ri = 0; ri < 8 && ri < rows.length; ++ri)
                        if (rows[ri] && rows[ri].active) { anyActive = true; break; }
                    if (!anyActive) continue;

                    // Per-voice pitch collection
                    var pitchesByVoice = {};
                    var tiesByVoice = {};

                    // Collect pitches, ties, symbols from the source chord
                    for (var row = 0; row < 8 && row < rows.length; ++row) {
                        var spec = rows[row];
                        if (!spec || !spec.active) continue;

                        var srcPitch = pitchForRowFromChord(chord, row);
                        if (srcPitch === null || srcPitch === undefined) continue;

                        var destPitch = clampInt(srcPitch + Number(spec.offset || 0), 0, 127);
                        var voice = clampInt(Number(spec.voice || 1), 1, 4);
                        var vKey = String(voice);

                        if (!pitchesByVoice[vKey]) pitchesByVoice[vKey] = [];
                        if (pitchesByVoice[vKey].indexOf(destPitch) === -1)
                            pitchesByVoice[vKey].push(destPitch);

                        // ✅ TIE QUEUE
                        if (nf.ties && sourceHasTieForward(chord, srcPitch)) {
                            if (!tiesByVoice[vKey]) tiesByVoice[vKey] = [];
                            if (!tiesByVoice[vKey].includes(destPitch))
                                tiesByVoice[vKey].push(destPitch);
                        }
                    }

                    // ----------------------------------------------------------------
                    // WRITE NOTES + QUEUE SYMBOLS/TIES PER VOICE
                    // ----------------------------------------------------------------
                    for (var vKey in pitchesByVoice) {
                        if (!pitchesByVoice.hasOwnProperty(vKey)) continue;

                        var list = pitchesByVoice[vKey];
                        if (!list || !list.length) continue;

                        var voice = parseInt(vKey, 10);

                        var c2 = curScore.newCursor();
                        c2.track = tgtStaff * 4 + (voice - 1);
                        c2.rewindToFraction(frac);
                        c2.setDuration(num, den);

                        var elNow = c2.element;
                        var isChord = elNow && elNow.type === Element.CHORD;
                        var isRest  = elNow && elNow.type === Element.REST;

                        if (!elNow || (!isChord && !isRest)) {
                            ensureWritableSlot(c2, num, den);
                        }
                        c2.rewindToFraction(frac);

                        var addToChord = !!(c2.element && c2.element.type === Element.CHORD);

                        try { c2.addNote(list[0], addToChord); } catch(e0) {}

                        for (var k = 1; k < list.length; ++k) {
                            c2.rewindToFraction(frac);
                            try { c2.addNote(list[k], true); } catch(eN) {}
                        }

                        let tTick2 = frac?.ticks ?? 0;

                        // ✅ TIES: queue tie operations
                        if (nf.ties && tiesByVoice[vKey]) {
                            for (let dp of tiesByVoice[vKey]) {
                                let key = `${tgtStaff}:${voice}:${tTick2}:${dp}`;
                                if (!pendingTiesSeen[key]) {
                                    pendingTiesSeen[key] = true;
                                    pendingTies.push({
                                                         tgtStaff: tgtStaff,
                                                         voice: voice,
                                                         tick: tTick2,
                                                         pitch: dp
                                                     });
                                }
                            }
                        }

                        if (nf.dynamics) {
                            const srcFrac = chord.fraction;
                            const srcTickInt = srcFrac?.ticks ?? 0;
                            const dset = dsetAll;  // or the cached dsetAll

                            // Log the intent clearly: we search dynamics on the SOURCE staff at this tick
                            try {
                                console.log("[DYNDBG] searching dynamics at tick", srcTickInt, "on srcStaff", srcStaff);
                            } catch (e) {}

                            let matched = 0;
                            for (let d of dset.dynamics) {
                                const sameStaff = (d.staffIdx === srcStaff);            // <— filter by source staff
                                const sameTick  = (d.tickInt === srcTickInt);           // (or use ±1 tolerance if needed)

                                if (sameStaff && sameTick) {
                                    matched++;
                                    pendingDynamics.push({
                                                             tgtStaff: tgtStaff,
                                                             voice: voice,
                                                             tick: srcTickInt,
                                                             text: d.text,
                                                             type: d.type,
                                                             kind: d.kind,
                                                             elementType: d.elementType,
                                                             subStyle: d.subStyle,
                                                             placement: d.placement,
                                                             srcElement: d.element,
                                                             srcStaffIdx: d.staffIdx,
                                                             srcTickInt: srcTickInt,
                                                             dynTickInt: d.tickInt
                                                         });
                                }

                                try {
                                    console.log("[DYNDBG] compare staff", d.staffIdx, "vs src", srcStaff,
                                                "ticks", d.tickInt, "vs", srcTickInt,
                                                "=>", (sameStaff && sameTick));
                                } catch (e) {}
                            }

                            try {
                                console.log("[DYNDBG] matched", matched, "dynamic(s) at srcTick", srcTickInt,
                                            "FROM srcStaff", srcStaff, "TO tgtStaff", tgtStaff, "voice", voice);
                            } catch (e) {}
                        }

                        // try {
                        //   for (let d of pendingDynamics)
                        //     debugListDynamicsAt(curScore, d.tgtStaff, d.srcTickInt);
                        // } catch(_){}

                        // ✅ HAIRPINS — 4.7‑safe tick handling
                        if (nf.hairpins) {
                            let srcTick = chord.fraction?.ticks ?? 0;
                            let dset = dsetAll;

                            function toIntTick(v) {
                                try {
                                    if (v === undefined || v === null) return undefined;
                                    if (typeof v === "number") return v;
                                    if (v.ticks !== undefined) return parseInt(v.ticks, 10);
                                    return fractionToTicks(v);
                                } catch (e) { return undefined; }
                            }

                            for (let hp of dset.hairpins) {
                                let st = toIntTick(hp.startTick);
                                let en = toIntTick(hp.endTick);
                                if (st === undefined || en === undefined) continue;
                                if (srcTick >= st && srcTick <= en) {
                                    pendingHairpins.push({
                                                             tgtStaff: tgtStaff,
                                                             voice: voice,
                                                             startTick: hp.startTick,
                                                             endTick: hp.endTick,
                                                             type: hp.type
                                                         });
                                }
                            }
                        }

                        // ✅ SYMBOLS: articulations & ornaments
                        if (nf.articulations || nf.ornaments) {
                            let queuedSymbolKeys = {};
                            if (chord && chord.articulations) {
                                if (nf.articulations) {
                                    for (let a of chord.articulations) {
                                        if (!a) continue;
                                        let sub = "";
                                        try { sub = a.subtypeName ? String(a.subtypeName()) : ""; } catch(_){}
                                        let key = `${a.type}\n${sub}\nchord`;

                                        if (!queuedSymbolKeys[key]) {
                                            queuedSymbolKeys[key] = true;
                                            pendingSymbols.push({
                                                                    kind: 'chord',
                                                                    tgtStaff: tgtStaff,
                                                                    voice: voice,
                                                                    tick: tTick2,
                                                                    src: a,
                                                                    srcStaff: srcStaff
                                                                });
                                        }
                                    }
                                }
                            }
                        }
                    } // end per-voice write
                } // end per-staff loop
            } // end per-source-chord loop

        } catch (e) {
            curScore.endCmd(true);
            console.log("[Orchestrator] ERROR:", String(e));
            return;
        }

        curScore.endCmd();

        // ------------------------------------------------------------------------
        // POST-WRITE OPERATIONS
        // ------------------------------------------------------------------------

        // ✅ SLURS
        if (nf.slurs && pendingSlurs.length > 0) {
            processPendingSlursAsync(pendingSlurs);
        }

        // ✅ DYNAMICS — symmetric creation (mirror source representation)
        if (nf.dynamics && pendingDynamics.length > 0) {
            curScore.startCmd(qsTr("Orchestrator: add dynamics"));
            try { console.log("[DYNDBG] creating", pendingDynamics.length, "dynamic(s)"); } catch (e) {}
            let okCount = 0;
            for (let d of pendingDynamics) {
                try {
                    console.log("[DYNDBG] createDynamic (symmetric)",
                                "tgtStaff=", d.tgtStaff, "voice=", d.voice,
                                "srcTickInt=", d.srcTickInt, "dynTickInt=", d.dynTickInt,
                                "kind=", d.kind, "eltType=", d.elementType,
                                "text=", String(d.text), "type=", d.type, "subStyle=", d.subStyle);
                } catch (e) {}
                let res = null;
                try {
                    res = createDynamicSymmetric(curScore, d.tgtStaff, d.tick, d);
                } catch(eDyn) {
                    try { console.log("[DYNDBG] createDynamicSymmetric error:", String(eDyn)); } catch(e2){}
                }
                if (res) {
                    okCount++;
                    try { console.log("[DYNDBG] ✅ createDynamicSymmetric -> ok (staff", d.tgtStaff, "voice", d.voice, ")"); } catch(_) {}
                } else {
                    try { console.log("[DYNDBG] ⚠️ createDynamicSymmetric -> null (staff", d.tgtStaff, "voice", d.voice, ")"); } catch(_) {}
                }
            }
            try { console.log("[DYNDBG] add dynamics complete; created:", okCount, "of", pendingDynamics.length); } catch(_) {}
            curScore.endCmd();
        }

        // ✅ HAIRPINS
        if (nf.hairpins && pendingHairpins.length > 0) {
            curScore.startCmd(qsTr("Orchestrator: add hairpins"));
            for (let h of pendingHairpins) {
                try { dynamicAPI.createHairpin(curScore, h.tgtStaff, h.startTick, h.endTick, h.type); } catch(eHp) {}
            }
            curScore.endCmd();
        }

        // ✅ TIES
        if (nf.ties && pendingTies.length > 0) {
            processPendingTiesAsync(pendingTies, 0);
        }

        // ✅ SYMBOLS (articulations & ornaments)
        if ((nf.articulations || nf.ornaments) && pendingSymbols.length > 0) {
            processPendingSymbolsAsync(pendingSymbols, 0);
        }
    }

    // ======================================================================
    //  DYNAMIC DETECTION + CREATION ENGINE  (Top-level global helpers)
    //  Integrated for Orchestrator (Dynamics + Hairpins)
    // ======================================================================

    // Detect all dynamics & hairpins in the score. (Keep your function signature/logging)
    function detectDynamics(score) {
        if (!score)
            return { dynamics: [], hairpins: [] };

        if (typeof detectDynamics.__loggedOnce === "undefined")
            detectDynamics.__loggedOnce = false;

        const dynamics = [];
        const hairpins = [];

        // Sample up to 5 text elements that did NOT qualify as dynamics (for diagnostics)
        let __sampledText = 0;

        // ----- DYNAMICS (glyph + styled text + token fallback) -----
        let seg = score.firstSegment();
        let __segCount = 0; // NEW: count segments we scanned

        while (seg) {
            __segCount++;

            let raw = seg.tick;
            let tInt = fractionToTicks(raw);

            // --- Path A: Prefer annotations array when available (4.7-safe) ---
            let handledViaAnnotations = false;
            try {
                if (seg.annotations && seg.annotations.length !== undefined) {
                    handledViaAnnotations = true;
                    for (let ai = 0; ai < seg.annotations.length; ++ai) {
                        const el = seg.annotations[ai];
                        if (!el) continue;

                        // Case A: glyph dynamics
                        if (el.type === Element.DYNAMIC) {
                            dynamics.push({
                                              kind: "glyph",
                                              elementType: Element.DYNAMIC,
                                              type: (function(){ try { return el.dynamicType; } catch(_) { return undefined; } })(),
                                              text: (function(){ try { return el.plainText; } catch(_) { return ""; } })(),
                                              tick: raw,
                                              tickInt: tInt,
                                              staffIdx: (function(){ try { return Math.floor(el.track / 4); } catch(_) { return -1; } })(),
                                              voice: (function(){ try { return el.track % 4; } catch(_) { return 0; } })(),
                                              element: el,
                                              segment: seg,
                                              offset: (function(){ try { return el.offset; } catch(_) { return undefined; } })(),
                                              placement: (function(){ try { return el.placement; } catch(_) { return undefined; } })()
                                          });
                            continue;
                        }

                        // Case B: StaffText / Expression used as dynamics
                        let isStaffText = false, isExpression = false;
                        try { isStaffText = (typeof Element.STAFF_TEXT !== "undefined" && el.type === Element.STAFF_TEXT); } catch(_) {}
                        try { isExpression = (typeof Element.EXPRESSION !== "undefined" && el.type === Element.EXPRESSION); } catch(_) {}

                        if (!isStaffText && !isExpression)
                            continue;

                        let rawTxt = "";
                        try { rawTxt = String(el.plainText ?? el.text ?? ""); } catch(_) {}

                        // Style-based recognition first
                        let isDynStyle = false, subStyleVal = undefined;
                        try {
                            if (typeof Tid !== "undefined" && typeof el.subStyle !== "undefined") {
                                subStyleVal = el.subStyle;
                                isDynStyle = (subStyleVal === Tid.DYNAMICS);
                            }
                        } catch(_) {}

                        // Fallback: token mapping ("p", "mf", "ff", …)
                        let mappedType = mapDynamicTextToType(rawTxt);

                        // Diagnostics: sample a few non-detected text items
                        if ((isStaffText || isExpression) && !isDynStyle && mappedType === undefined && __sampledText < 5) {
                            __sampledText++;
                            try {
                                console.log("[DYNDBG] sample text@tick", tInt,
                                            "elt", (isStaffText ? "STAFF_TEXT" : "EXPRESSION"),
                                            "subStyle=", (typeof el.subStyle !== "undefined" ? el.subStyle : "(n/a)"),
                                            "plainText=", String(rawTxt));
                            } catch (_) {}
                        }

                        if (isDynStyle || mappedType !== undefined) {
                            dynamics.push({
                                              kind: "text",
                                              elementType: isStaffText ? Element.STAFF_TEXT : Element.EXPRESSION,
                                              subStyle: (isDynStyle ? subStyleVal : undefined),
                                              text: rawTxt,
                                              type: mappedType,               // may be undefined if token unrecognized
                                              tick: raw,
                                              tickInt: tInt,
                                              staffIdx: (function(){ try { return Math.floor(el.track / 4); } catch(_) { return -1; } })(),
                                              voice: (function(){ try { return el.track % 4; } catch(_) { return 0; } })(),
                                              element: el,
                                              segment: seg,
                                              placement: (function(){ try { return el.placement; } catch(_) { return undefined; } })()
                                          });
                        }
                    }
                }
            } catch(_) {}

            // --- Path B: Fallback to elementAt(track) scan when annotations are absent ---
            if (!handledViaAnnotations) {
                for (let track = 0; track < score.ntracks; ++track) {
                    const el = seg.elementAt(track);
                    if (!el) continue;

                    // (the existing glyph / text cases unchanged)
                    // ... (reuse your current logic here) ...
                }
            }

            // Advance across the whole score in time order (4.7-safe)
            seg = (typeof seg.nextInScore !== "undefined" && seg.nextInScore)
                    ? seg.nextInScore
                    : (typeof seg.next !== "undefined" ? seg.next : null);
        }

        // Emit a reliable segment scan count
        try { console.log("[DYNDBG] segment scan count:", __segCount); } catch(e){}

        // ----- HAIRPINS (unchanged from your code) -----
        const sp = score.spanners;
        for (let i = 0; i < sp.length; ++i) {
            const s = sp[i];
            if (s && s.type === Element.HAIRPIN) {
                hairpins.push({
                                  type: s.hairpinType,
                                  startTick: s.startTick,
                                  endTick: s.endTick,
                                  element: s
                              });
            }
        }

        if (!detectDynamics.__loggedOnce) {
            try {
                console.log("[DYNDBG] detectDynamics summary: dynamics=", dynamics.length, "hairpins=", hairpins.length);
                let cap = Math.min(8, dynamics.length);
                for (let i = 0; i < cap; ++i) {
                    let d = dynamics[i];
                    console.log("[DYNDBG] DET dyn[", i, "] kind=", d.kind,
                                "tickInt=", d.tickInt, "staffIdx=", d.staffIdx, "voice=", d.voice,
                                "type=", d.type, "text=", String(d.text), "eltType=", d.elementType, "subStyle=", d.subStyle);
                }
            } catch (e) {}
            detectDynamics.__loggedOnce = true;
        }

        return { dynamics, hairpins };
    }

    // [DYN-SYM] Text token → DynamicType map (best-effort)
    function mapDynamicTextToType(rawText) {
        if (!rawText) return undefined;
        var t = String(rawText).replace(/\s+/g, "").toLowerCase();

        // Canonical tokens
        var map = {
            "pppppp":"PPPPPP","ppppp":"PPPPP","pppp":"PPPP","ppp":"PPP","pp":"PP","p":"P",
            "mp":"MP","mf":"MF",
            "f":"F","ff":"FF","fff":"FFF","ffff":"FFFF","fffff":"FFFFF","ffffff":"FFFFFF",
            "fp":"FP","pf":"PF",
            "sf":"SF","sfz":"SFZ","sff":"SFF","sffz":"SFFZ","sfff":"SFFF","sfffz":"SFFFZ",
            "sfp":"SFP","sfpp":"SFPP","rfz":"RFZ","rf":"RF","fz":"FZ","z":"Z","n":"N"
        };
        var key = map[t];
        if (!key) return undefined;

        // Return numeric enum if available
        try {
            return DynamicType[key];
        } catch (_) {
            return undefined;
        }
    }

    // Create a simple dynamic (“p”, “mf”, “ff”…) — instrumentation only
    function createDynamic(score, staffIdx, tick, text) {
        if (!score) return null;
        const c = score.newCursor();

        // Dynamics usually go on voice 1; use track = staffIdx*4 + 0
        c.track = staffIdx * 4 + 0;

        try {
            let kind = (typeof tick === "number") ? "absTick" :
                                                    (tick && tick.ticks !== undefined) ? "Fraction(ticks="+tick.ticks+")" :
                                                                                         "UnknownTick";
            console.log("[DYNDBG] createDynamic rewind", kind, "-> staffIdx", staffIdx, "text", String(text));
        } catch (e) {}

        try { c.rewindToFraction(tick); } catch (eRF) {
            try { console.log("[DYNDBG] rewindToFraction failed; error:", String(eRF)); } catch(e2){}
        }

        const d = newElement(Element.DYNAMIC);
        if (!d) return null;
        d.plainText = text;

        try {
            c.add(d);
            console.log("[DYNDBG] dynamic added at staffIdx", staffIdx, "with text", String(text));
        } catch (eAdd) {
            try { console.log("[DYNDBG] add dynamic failed:", String(eAdd)); } catch(e2){}
            return null;
        }
        return d;
    }

    // [DYN-SYM] Create dynamic using the same representation we detected
    function createDynamicSymmetric(score, staffIdx, tick, d) {
        if (!score || !d) return null;

        // --- ENTER LOG ---
        try {
            var tinfo = (tick && tick.ticks !== undefined) ? tick.ticks : tick;
            console.log("[DYNDBG] >> enter createDynamicSymmetric",
                        "staff=", staffIdx, "tick=", tinfo,
                        "kind=", d.kind, "type=", d.type, "text=", String(d.text));
        } catch(_) {}

        // Common cursor positioning & logging
        const c = score.newCursor();

        // Choose a destination voice track. Dynamics aren’t voice-specific,
        // but the cursor needs a concrete track. Default to voice 1 (index 0).
        let vIndex = 0;
        try {
            if (d && d.voice !== undefined && d.voice !== null) {
                // d.voice is 1..4 from your orchestration row; clamp to 0..3
                const vv = Math.max(1, Math.min(4, parseInt(d.voice, 10) || 1));
                vIndex = vv - 1;
            }
        } catch (_) { vIndex = 0; }

        // IMPORTANT: set track first, then position; this mirrors your note-writing code.
        c.track = staffIdx * 4 + vIndex;
        // Convert anything → absolute tick and rewind by tick for this build
        function toIntTick(v) {
            try {
                if (typeof v === "number") return v;
                if (v && v.ticks !== undefined) return parseInt(v.ticks, 10);
                return fractionToTicks(v);
            } catch(_) { return 0; }
        }
        const tInt = toIntTick(tick);
        try { c.rewindToTick(tInt); } catch (eRF) {
            try { console.log("[DYNDBG] rewindToFraction failed; error:", String(eRF)); } catch(e2){}
        }

        // Diagnostics: where did the cursor actually land?
        try { console.log("[DYNDBG] cursor at tick:", c.tick, "expected:", tInt, "track:", c.track); } catch(_){}

        // -------- De-dupe on this segment: skip if a dynamic already exists --------
        try {
            const seg = c.segment;    if (seg && seg.annotations) {
                for (let i = 0; i < seg.annotations.length; ++i) {
                    const el = seg.annotations[i];
                    if (el && el.type === Element.DYNAMIC && Math.floor((el.track||0)/4) === staffIdx) {
                        console.log("[DYNDBG] existing dynamic at tick", tInt, "staff", staffIdx, "→ skip add");
                        return el; // treat as success
                    }
                }
            }
        } catch(_) {}

        // -------- Path A (robust): clone the source element when available --------
        if (d.srcElement) {

            try {

                let copy = null;
                try { copy = d.srcElement.clone(); } catch(_) { copy = null; }
                if (copy) {

                    // normalize a few properties for safety
                    try { if (typeof copy.visible !== "undefined") copy.visible = true; } catch(_){}
                    try { if (typeof copy.autoplace !== "undefined") copy.autoplace = true; } catch(_){}
                    try { if (typeof d.placement !== "undefined" && typeof copy.placement !== "undefined") copy.placement = d.placement; } catch(_){}
                    c.add(copy);
                    console.log("[DYNDBG] ++ added CLONED dynamic staff=", staffIdx, "track=", c.track, "tick=", tInt);
                    return copy;
                }
            } catch(eClone) {
                try { console.log("[DYNDBG] clone-add dynamic failed:", String(eClone)); } catch(_){}
            }
        }

        // -------- Path B: create new (fallback) --------
        if (d.kind === "glyph" || (d.kind === "text" && d.type !== undefined && d.elementType === Element.DYNAMIC)) {
            const dyn = newElement(Element.DYNAMIC);
            if (!dyn) return null;
            let setTypeOk = false;
            try { if (d.type !== undefined && d.type !== null) { dyn.dynamicType = d.type; setTypeOk = true; } } catch(_) {}
            try { if (!setTypeOk && d.text) dyn.plainText = d.text; } catch(_) {}
            try { if (typeof dyn.visible !== "undefined") dyn.visible = true; } catch(_){}
            try { if (typeof dyn.autoplace !== "undefined") dyn.autoplace = true; } catch(_){}
            try { if (typeof d.placement !== "undefined" && typeof dyn.placement !== "undefined") dyn.placement = d.placement; } catch(_){}
            try { c.add(dyn); } catch(eAdd) { try { console.log("[DYNDBG] add dynamic failed:", String(eAdd)); } catch(e2){}; return null; }
            try {
                console.log("[DYNDBG] ++ added glyph dynamic","staff=", staffIdx, "track=", c.track, "tick=", tInt,
                            "type=", (function(){ try { return dyn.dynamicType; } catch(_){ return "(?)"; } })());
            } catch(_) {}
            return dyn;
        }

        // Case B: text dynamic (mirror original element type, keep style if we have it)
        if (d.kind === "text") {
            // Default to Staff Text when in doubt
            const et = (d.elementType === Element.EXPRESSION) ? Element.EXPRESSION : Element.STAFF_TEXT;
            const t = newElement(et);
            if (!t) return null;

            // Preserve text token
            try { if (d.text) t.plainText = d.text; } catch(_) {}

            // Preserve Dynamics style when provided
            try {
                if (typeof d.subStyle !== "undefined" && d.subStyle !== null && typeof t.subStyle !== "undefined") {
                    t.subStyle = d.subStyle; // typically Tid.DYNAMICS
                } else if (typeof Tid !== "undefined" && typeof t.subStyle !== "undefined") {
                    // If original had no style but we know it is a dynamic token, you can opt in:
                    // t.subStyle = Tid.DYNAMICS;
                }
            } catch(_) {}

            // Keep placement if it existed
            try { if (typeof d.placement !== "undefined" && typeof t.placement !== "undefined") t.placement = d.placement; } catch(_) {}

            try { c.add(t); } catch(eAdd2) { try { console.log("[DYNDBG] add text-dynamic failed:", String(eAdd2)); } catch(e2){}; return null; }
            return t;
        }

        return null;
    }

    function debugListDynamicsAt(score, staffIdx, tickInt) {
        try {
            const c = score.newCursor();
            c.track = staffIdx * 4;
            c.rewindToTick(tickInt);
            const seg = c.segment;
            let count = 0;
            if (seg && seg.annotations) {
                for (let i = 0; i < seg.annotations.length; ++i) {
                    const el = seg.annotations[i];
                    if (el && el.type === Element.DYNAMIC) {
                        count++;
                        try {
                            console.log("[DYNDBG] (verify) staff", Math.floor(el.track/4),
                                        "track", el.track, "tick", tickInt,
                                        "type", (el.dynamicType !== undefined ? el.dynamicType : "(n/a)"),
                                        "text", String(el.plainText),
                                        "visible", (el.visible !== undefined ? el.visible : "(n/a)"));
                        } catch(_){}
                    }
                }
            }
            console.log("[DYNDBG] (verify) total dynamics at tick", tickInt, "=", count, "for staff", staffIdx);
        } catch(e) {
            console.log("[DYNDBG] (verify) error:", String(e));
        }
    }

    // Create a crescendo or decrescendo hairpin between two ticks.
    function createHairpin(score, staffIdx, tickStart, tickEnd, hairpinType) {
        if (!score) return null;

        function rewindToPos(c, v) {
            try {
                if (typeof v === "number") { c.rewindToTick(v); return; }
                if (v && v.ticks !== undefined) { c.rewindToFraction(v); return; }
                if (v && v.numerator !== undefined && v.denominator !== undefined) { c.rewindToFraction(v); return; }
            } catch (e) {}
            c.rewindToTick(0);
        }

        const c = score.newCursor();
        c.track = staffIdx * 4 + 0;

        const hp = newElement(Element.HAIRPIN);
        if (!hp) return null;
        hp.hairpinType = hairpinType;

        rewindToPos(c, tickStart);
        c.add(hp);
        rewindToPos(c, tickEnd);
        c.add(hp);
        return hp;
    }

    // Convenience: add a dynamic at (measureNo, beat).
    function addDynamicByBeat(score, staffIdx, measureNo, beat, text) {
        if (!score)
            return null;

        let m = score.firstMeasure();
        while (m && m.no !== (measureNo - 1))
            m = m.nextMeasure;

        if (!m)
            return null;

        const ts = m.timeSig(m.tick());
        const den = ts.denominator;

        const beatFrac = api.fraction((beat - 1) * (score.division / den), score.division);
        const tgt = m.tick().plus(beatFrac);

        return createDynamic(score, staffIdx, tgt, text);
    }

    // ---------- Notation-copy helpers (normal mode) ----------

    // Return a CHORD at (staffIdx, voice 1..4, absolute tick), or null
    function findChordAt(staffIdx, voice, absTick) {
        try {
            var c = curScore.newCursor()
            c.track = staffIdx * 4 + (voice - 1)
            c.rewindToTick(absTick)
            if (c.element && c.element.type === Element.CHORD)
                return c.element
        } catch (e) {}
        return null
    }

    // Return a CHORD at or near 'absTick' (exact, then ±1 tick), or null.
    function findChordAtOrNearTick(staffIdx, voice, absTick) {
        var ch = findChordAt(staffIdx, voice, absTick);
        if (ch) return ch;
        ch = findChordAt(staffIdx, voice, absTick - 1);
        if (ch) return ch;
        return findChordAt(staffIdx, voice, absTick + 1);
    }

    // Find the absolute tick of the next chord (after 'startTick')
    // on the given staff and voice. Returns null if none exists.
    function findNextChordTick(staffIdx, voice, startTick) {
        try {
            var cursor = curScore.newCursor();
            cursor.track = staffIdx * 4 + (voice - 1);
            cursor.rewindToTick(startTick);

            // Step at least once to move beyond the current chord
            if (!cursor.next())
                return null;

            // Walk forward until we find a chord
            while (cursor.segment) {
                var el = cursor.element;
                if (el && el.type === Element.CHORD)
                    return cursor.tick;
                if (!cursor.next())
                    break;
            }
        } catch (e) {}

        return null;
    }

    // Resolve the ideal slur end tick (t1) giving priority to:
    // 1) next chord on the TARGET staff/voice
    // 2) next chord on the SOURCE staff (same voice if possible)
    // 3) next source-chord in srcChords[]
    // 4) fallback: return t0
    function resolveSlurEndTick(tgtStaff, voice, t0, srcStaff, srcChords) {

        // 1) Target staff: find next chord in this voice
        var tTarget = findNextChordTick(tgtStaff, voice, t0);
        if (tTarget !== null)
            return tTarget;

        // 2) Source staff: same voice if possible
        var tSource = findNextChordTick(srcStaff, voice, t0);
        if (tSource !== null)
            return tSource;

        // 3) Next chord in the source chord list (ascending time)
        for (var i = 0; i < srcChords.length; ++i) {
            var ch = srcChords[i];
            var tt = (ch.fraction && ch.fraction.ticks !== undefined)
                    ? ch.fraction.ticks
                    : (ch.parent ? ch.parent.tick : 0);

            if (tt > t0)
                return tt;
        }

        // 4) Fallback: zero‑length slur
        return t0;
    }

    // Return the NOTE object in that chord with the specified MIDI pitch, or null
    function findNoteInChordByPitch(ch, pitch) {
        if (!ch || !ch.notes) return null
        for (var i = 0; i < ch.notes.length; ++i) {
            var n = ch.notes[i]
            if (n && n.pitch === pitch) return n
        }
        return null
    }

    // Return NOTE at (staffIdx, voice 1..4, tick, pitch), or null
    function findNoteAt(staffIdx, voice, absTick, pitch) {
        var ch = findChordAt(staffIdx, voice, absTick)
        return findNoteInChordByPitch(ch, pitch)
    }

    // Best-effort: pick ANY note near (staffIdx, voice, tick) to anchor a slur.
    // Try exact tick, then ±1 tick. Prefer highest pitch when multiple notes exist.
    function findAnyAnchorNoteAt(staffIdx, voice, absTick) {
        function bestNoteInChord(ch) {
            if (!ch || !ch.notes || ch.notes.length === 0) return null;
            var best = ch.notes[0];
            for (var i = 1; i < ch.notes.length; ++i)
                if (ch.notes[i].pitch > best.pitch) best = ch.notes[i];
            return best;
        }
        var ch0 = findChordAt(staffIdx, voice, absTick);
        var n0 = bestNoteInChord(ch0);
        if (n0) return n0;

        var ch1 = findChordAt(staffIdx, voice, absTick - 1);
        var n1 = bestNoteInChord(ch1);
        if (n1) return n1;

        var ch2 = findChordAt(staffIdx, voice, absTick + 1);
        var n2 = bestNoteInChord(ch2);
        if (n2) return n2;

        return null;
    }

    // Return true if we could attach 'srcEl' to the top NOTE of (staffIdx, voice, tick).
    // Falls back to the chord itself only when no note is available.
    function attachSymbolToTopNote(staffIdx, voice, absTick, srcEl) {
        var ch = findChordAt(staffIdx, voice, absTick);
        if (!ch || !srcEl) return false;

        // Pick highest pitch as the visual anchor (consistent with your slur anchor helper)
        var note = null;
        if (ch.notes && ch.notes.length > 0) {
            note = ch.notes[0];
            for (var i = 1; i < ch.notes.length; ++i)
                if (ch.notes[i].pitch > note.pitch) note = ch.notes[i];
        }

        // Prefer attaching to the NOTE; if none (edge cases), fall back to the CHORD.
        var owner = note ? note : ch;
        return cloneAndAttachIfMissing(owner, srcEl);
    }

    // Return true if there is a CHORD on (staffIdx, voice) at 'tick' or within a tiny wiggle.
    function hasChordAtOrNearTick(staffIdx, voice, tick) {
        // Try exact match first
        if (findChordAt(staffIdx, voice, tick)) return true;
        // Small wiggle (±1 ticks) to survive segment/spanner rounding differences
        // You can enlarge this if needed, but ±1 is usually enough.
        if (findChordAt(staffIdx, voice, tick - 1)) return true;
        if (findChordAt(staffIdx, voice, tick + 1)) return true;
        return false;
    }

    function cloneAndAttachIfMissing(owner, el, forcedTrack) {
        try {
            if (!owner || !el)
                return false;

            // -------- classify ----------
            var t = el.type;
            var isArticLike = (t === Element.ARTICULATION) ||
                    (t === Element.ORNAMENT)   ||
                    (t === Element.FERMATA);

            function subNameOf(e) {
                try { return e && e.subtypeName ? String(e.subtypeName()) : ""; } catch (_) {}
                return "";
            }
            function subIdOf(e) {
                try { return (e && e.subtype !== undefined) ? e.subtype : undefined; } catch (_) {}
                return undefined;
            }
            var subName = subNameOf(el);
            var subId   = subIdOf(el);

            // -------- resolve final owner (CHORD for articulation-like) ----------
            var resolvedOwner = owner;
            if (isArticLike && owner && owner.type === Element.NOTE) {
                try { if (owner.parent && owner.parent.type === Element.CHORD) resolvedOwner = owner.parent; } catch (_) {}
            }

            // expected track is only used for pre-add de-dupe
            var expectedTrack = (typeof forcedTrack === "number")
                    ? forcedTrack
                    : (resolvedOwner && resolvedOwner.track !== undefined ? resolvedOwner.track : undefined);

            // -------- local de-dupe on owner ----------
            function alreadyHas(o, trackScoped) {
                try {
                    function matches(e2) {
                        if (!e2) return false;
                        if (e2.type !== t) return false;

                        // Prefer numeric subtype equality when available (most reliable)
                        var s2 = subIdOf(e2);
                        if (subId !== undefined && s2 !== undefined) {
                            if (s2 !== subId) return false;
                        } else {
                            // Fallback to name
                            if (subNameOf(e2) !== subName) return false;
                        }

                        if (trackScoped && typeof expectedTrack === "number") {
                            try { if (e2.track !== expectedTrack) return false; } catch (_) {}
                        }
                        return true;
                    }
                    if (o.elements) {
                        for (var i = 0; i < o.elements.length; ++i)
                            if (matches(o.elements[i])) return true;
                    }
                    if (o.articulations) {
                        for (var j = 0; j < o.articulations.length; ++j)
                            if (matches(o.articulations[j])) return true;
                    }
                } catch (_) {}
                return false;
            }

            // pre-add de-dupe (track-scoped so a mark on another staff doesn't suppress us)
            if (alreadyHas(resolvedOwner, /*trackScoped*/true))
                return false;

            // inside cloneAndAttachIfMissing(owner, el, forcedTrack) { … }
            function makeCandidateFromSource(src) {
                // try to construct a fresh element of the same type
                var e = null;
                try { e = newElement(src.type); } catch (_) { e = null; }
                if (!e) {
                    // last resort: clone the source
                    try { e = src.clone(); } catch (_) { e = null; }
                }
                if (!e) return null;

                // 1) First, copy the symbol if the wrapper exposes it (most reliable)
                try {
                    if (src.symbol !== undefined && e.symbol !== undefined) {
                        var s = String(src.symbol);
                        if (s && s.toLowerCase() !== "nosymbol")
                            e.symbol = s;  // e.g., "articStaccatoBelow", "articAccentAbove"
                    }
                } catch (_) {}

                // 2) If symbol wasn’t available, infer from subtypeName()
                try {
                    // e.subtype / e.subtypeName aren’t trustworthy pre-add on some builds;
                    // infer using the source’s subtypeName.
                    var subName = "";
                    try { subName = src.subtypeName ? String(src.subtypeName()) : ""; } catch (_){}
                    var lower = subName.toLowerCase();

                    function ab(base) {
                        if (lower.indexOf("above") >= 0) return base + "Above";
                        if (lower.indexOf("below") >= 0) return base + "Below";
                        return base + "Above"; // default (Above)
                    }

                    if (e.symbol !== undefined) {
                        if (!e.symbol || String(e.symbol).toLowerCase() === "nosymbol") {
                            if (src.type === Element.ARTICULATION) {
                                if (lower.indexOf("staccatissimo") >= 0) e.symbol = ab("articStaccatissimo");
                                else if (lower.indexOf("staccato") >= 0)  e.symbol = ab("articStaccato");
                                else if (lower.indexOf("tenuto") >= 0)    e.symbol = ab("articTenuto");
                                else if (lower.indexOf("marcato") >= 0)   e.symbol = ab("articMarcato");
                                else if (lower.indexOf("accent") >= 0)    e.symbol = ab("articAccent");
                            } else if (src.type === Element.FERMATA) {
                                if (lower.indexOf("fermata") >= 0)
                                    e.symbol = (lower.indexOf("above") >= 0) ? "fermataAbove" : "fermataBelow";
                            }
                            // (ORNAMENTs: leave to clone fallback or extend with your own map later)
                        }
                    }
                } catch (_) {}

                // 3) Anchor & direction normalization (safe no-ops if property missing)
                try {
                    if (e.articulationAnchor !== undefined) {
                        if (typeof ArticulationAnchor !== 'undefined' && ArticulationAnchor.CHORD !== undefined)
                            e.articulationAnchor = ArticulationAnchor.CHORD;
                        else
                            e.articulationAnchor = 2; // numeric fallback
                    }
                } catch (_){}

                // Do NOT set e.track; owner.add() will inherit owner’s track.

                return e;
            }

            function attemptAdd(target) {
                try {
                    if (!target || typeof target.add !== "function")
                        return false;

                    var cand = makeCandidateFromSource(el);
                    if (!cand) return false;

                    // diagnostics (subtype id + name)
                    try {
                        var cSub = subIdOf(cand);
                        console.log("[Orchestrator] DEBUG add", subName, "-> tgtStaff",
                                    Math.floor((expectedTrack||0)/4),
                                    "owner.track", (target.track!==undefined?target.track:"?"),
                                    "cand.track", (cand.track!==undefined?cand.track:"?"),
                                    "src.symbol", (el.symbol!==undefined?String(el.symbol):"(none)"),
                                    "cand.symbol", (cand.symbol!==undefined?String(cand.symbol):"(none)"));
                    } catch(_){}

                    target.add(cand);

                    // Post-add presence check: RELAX track requirement (some builds update track lazily)
                    return alreadyHas(target, /*trackScoped*/false);
                } catch (_) {
                    return false;
                }
            }

            if (attemptAdd(resolvedOwner))
                return true;

            // last resort: if original owner was a NOTE, try its chord explicitly once
            try {
                if (owner && owner.type === Element.NOTE && owner.parent && owner.parent.type === Element.CHORD)
                    return attemptAdd(owner.parent);
            } catch (_) {}

            return false;
        } catch (_) {
            return false;
        }
    }

    //
    // MuseScore 4.7–compatible slur creation
    // Slurs can ONLY be created by selecting two notes and calling cmd("add-slur").
    // Notes and Chords do NOT implement addSpanner() in your build.
    //
    function processPendingSlursAsync(slurQueue) {
        console.log("[SLURDBG] processPendingSlursAsync running, items:", slurQueue.length);

        for (let S of slurQueue) {
            console.log(
                        "[SLURDBG] slur attempt:",
                        "tgtStaff=", S.tgtStaff,
                        "voice=", S.voice,
                        "t0=", S.t0,
                        "t1=", S.t1
                        );

            // --- Anchor chords from your existing helper ---
            const ch0 = findAnchorNote(S.tgtStaff, S.voice, S.t0);
            const ch1 = findAnchorNote(S.tgtStaff, S.voice, S.t1);

            if (!ch0 || !ch1) {
                console.log("[SLURDBG] missing anchor chord(s)");
                continue;
            }

            // Pick highest note from each chord (your policy)
            const n0 = ch0.notes.reduce((a,b)=>a.pitch>b.pitch?a:b);
            const n1 = ch1.notes.reduce((a,b)=>a.pitch>b.pitch?a:b);

            console.log(
                        "[SLURDBG] anchor notes:",
                        "n0?", !!n0,
                        "n1?", !!n1
                        );

            if (!n0 || !n1)
                continue;

            try {
                // -------------------------------------------------------
                // ✅ MuseScore 4.7 slur creation procedure:
                // 1. Clear selection
                // 2. Select start note
                // 3. Select end note
                // 4. Call: cmd("add-slur")
                // -------------------------------------------------------
                curScore.selection.clear();
                curScore.selection.select(n0, true);
                curScore.selection.select(n1, true);

                console.log("[SLURDBG] issuing add-slur command");
                cmd("add-slur");

            } catch (e) {
                console.log("[SLURDBG] ERROR creating slur via command:", String(e));
            }
        }

        // Final cleanup
        try { curScore.selection.clear(); } catch(_){}
    }

    function writeSlursForSelection(srcStaff, srcChords) {
        const slurQueue = queueSlursForOrchestration(srcStaff, srcChords);
        Qt.callLater(() => processPendingSlursAsync(slurQueue));
    }

    function processPendingTiesAsync(list, startIndex) {
        try {
            var batch = 32; // moderate batch
            var end = Math.min(list.length, startIndex + batch);

            for (var i = startIndex; i < end; ++i) {
                var T = list[i];
                if (!T) continue;

                var nStart = findNoteAt(T.tgtStaff, T.voice, T.tick, T.pitch);
                if (!nStart) continue;
                try { if (nStart.tieForward) continue; } catch (eTF) {}

                withSingleSelection(nStart, "chord-tie"); // creates tie to next same-pitch note
            }

            try {
                console.log("[Orchestrator] ties created batch", startIndex, "…", end, "of", list.length);
            } catch (eDbg) {}

            if (end < list.length) {
                Qt.callLater(function () { processPendingTiesAsync(list, end); });
            }
        } catch (eTopTie) {
            try { console.log("[Orchestrator] tie post-process error:", String(eTopTie)); } catch (eLog) {}
        }
    }

    // Async post-processor for articulations / ornaments / fermatas
    function processPendingSymbolsAsync(list, startIndex) {
        try {
            var batch = 32; // keep UI responsive
            var end = Math.min(list.length, startIndex + batch);

            // Wrap each batch in its own command so owner.add(copy) persists
            curScore.startCmd(qsTr("Orchestrator: copy symbols"));

            for (var i = startIndex; i < end; ++i) {
                var S = list[i]

                // Skip tremolo elements in this pass to avoid renderer asserts
                try { if (S.src && S.src.type === Element.TREMOLO) continue; } catch (_) {}

                if (!S) continue
                if (S.srcStaff !== undefined && S.tgtStaff === S.srcStaff) {
                    try { console.log("[Orchestrator] SKIP symbol targeting source staff at tick", S.tick); } catch(_) {}
                    continue
                }
                var subtype = ""; try { subtype = (S.src && S.src.subtypeName) ? String(S.src.subtypeName()) : ""; } catch (eSN) {}
                var ok = false;
                var tickHere = (typeof S.tick === 'number') ? S.tick : 0;

                // Compute exact destination track once
                var forcedTrack = (S.tgtStaff >= 0 && S.voice >= 1 && S.voice <= 4)
                        ? (S.tgtStaff * 4 + (S.voice - 1))
                        : undefined;

                // If this symbol was queued for a specific destination note, try that first.
                if (S.kind === 'note' && S.pitch !== undefined) {
                    var dstNote = null;
                    try {
                        dstNote = findNoteAt(S.tgtStaff, S.voice, tickHere, S.pitch)
                                || findNoteAt(S.tgtStaff, S.voice, tickHere - 1, S.pitch)
                                || findNoteAt(S.tgtStaff, S.voice, tickHere + 1, S.pitch);
                    } catch (_) {}
                    if (dstNote && S.src) {
                        try { ok = !!cloneAndAttachIfMissing(dstNote, S.src, forcedTrack); } catch (_) { ok = false; }
                    }
                }

                // Fallback: attach to the destination at/near this time
                if (!ok) {
                    var dstChord = findChordAtOrNearTick(S.tgtStaff, S.voice, tickHere);

                    // If findChordAtOrNearTick() returns a chord on the wrong staff, ignore it.
                    function chordOnCorrectStaff(ch) {
                        try { return ch && ch.staffIdx === S.tgtStaff; } catch (_) {}
                        return false;
                    }

                    if (chordOnCorrectStaff(dstChord) && S.src) {
                        // Articulation-like items should attach to the CHORD (anchor controls visual placement)
                        ok = !!cloneAndAttachIfMissing(dstChord, S.src, forcedTrack);
                    }
                }

                console.log("[Orchestrator] attach sym", subtype, "-> staff", S.tgtStaff, "voice", S.voice, "tick", tickHere, "kind", (S.kind||"chord"), "ok", ok);
            }

            // End the batch command
            curScore.endCmd();

            try {
                console.log("[Orchestrator] symbols created batch", startIndex, "…", end, "of", list.length);
            } catch (eDbg) {}
            if (end < list.length) {
                Qt.callLater(function () { processPendingSymbolsAsync(list, end); });
            }
        } catch (eTopSym) {
            // If anything throws before endCmd, try to safely roll back
            try { curScore.endCmd(true); } catch (eEnd) {}
            try { console.log("[Orchestrator] symbol post-process error:", String(eTopSym)); } catch (eLog) {}
        }
    }

    // Select exactly one Element and do an action; leaves selection clear afterwards.
    function withSingleSelection(el, actionName) {
        try {
            curScore.selection.clear()
            if (el) curScore.selection.select(el, true)
            if (actionName && actionName.length) cmd(actionName)
        } catch (e) {} finally {
            try { curScore.selection.clear() } catch (e2) {}
        }
    }

    // Utility: does a source chord contain a note of 'srcPitch' that ties forward?
    function sourceHasTieForward(chord, srcPitch) {
        try {
            if (!chord || !chord.notes) return false
            for (var i = 0; i < chord.notes.length; ++i) {
                var n = chord.notes[i]
                if (n && n.pitch === srcPitch && n.tieForward) return true
            }
        } catch (e) {}
        return false
    }

    //-------------------------------------------------------------
    //  Slur helper functions (ported from Keyswitch Creator)
    //-------------------------------------------------------------

    // Convert Fraction-like objects safely into absolute ticks.
    function fractionToTicks(fr) {
        try {
            if (typeof fr === "number")
                return fr;

            if (fr && fr.ticks !== undefined)
                return parseInt(fr.ticks, 10);

            if (fr && fr.numerator !== undefined && fr.denominator !== undefined) {
                var num = parseInt(fr.numerator, 10);
                var den = parseInt(fr.denominator, 10);
                if (!isNaN(num) && !isNaN(den) && den !== 0)
                    return Math.floor(num * division / den);   // division = ticks/quarter
            }
        } catch (e) {}

        return 0;
    }

    // Get slur start tick using all MS4-exposed properties.
    function spStartTick(s) {
        try { if (s.spannerTick !== undefined) return fractionToTicks(s.spannerTick); } catch (e) {}
        try { if (s.tick !== undefined)        return fractionToTicks(s.tick);        } catch (e) {}
        try {
            if (s.startSegment && s.startSegment.tick !== undefined)
                return fractionToTicks(s.startSegment.tick);
        } catch (e) {}

        return 0;
    }

    // Determine the staff index where the slur begins.
    function spStartStaffIdx(s) {
        try { if (s.staff && s.staff.index !== undefined) return s.staff.index; } catch (e) {}
        try { if (s.track !== undefined)                  return Math.floor(s.track / 4); } catch (e) {}
        try { if (s.spannerTrack2 !== undefined)          return Math.floor(s.spannerTrack2 / 4); } catch (e) {}

        return -1;
    }

    // Get slur end tick using all MS4-exposed properties.
    function spEndTick(s) {
        try { if (s.spannerTick2 !== undefined) return fractionToTicks(s.spannerTick2); } catch (e) {}
        try { if (s.tick2 !== undefined)       return fractionToTicks(s.tick2); }       catch (e) {}
        try {
            if (s.endSegment && s.endSegment.tick !== undefined)
                return fractionToTicks(s.endSegment.tick);
        } catch (e) {}
        return 0;
    }

    //
    // 4.7-aware slur info extractor
    //
    function slurInfo(slur) {
        // Convert Fraction-like or raw values into ticks
        function toTicks(v) {
            if (!v) return 0;
            if (typeof v === "number") return v;
            try {
                if (v.ticks !== undefined)
                    return parseInt(v.ticks, 10);
            } catch (_) {}
            try {
                if (v.numerator !== undefined && v.denominator !== undefined) {
                    var num = parseInt(v.numerator, 10);
                    var den = parseInt(v.denominator, 10);
                    if (!isNaN(num) && !isNaN(den) && den !== 0)
                        return Math.floor((num * division) / den);
                }
            } catch (_) {}
            return 0;
        }

        // ---------------------------
        // 4.7‑aware start tick
        // ---------------------------
        let st = 0;

        // 1) spannerTick
        try {
            if (slur.spannerTick !== undefined)
                st = toTicks(slur.spannerTick);
        } catch (_) {}

        // 2) tick
        if (!st) {
            try {
                if (slur.tick !== undefined)
                    st = toTicks(slur.tick);
            } catch (_) {}
        }

        // 3) startSegment.tick
        if (!st) {
            try {
                if (slur.startSegment && slur.startSegment.tick !== undefined)
                    st = toTicks(slur.startSegment.tick);
            } catch (_) {}
        }

        // 4) segment[0] fallback
        if (!st && slur.segments && slur.segments.length > 0) {
            try {
                const seg0 = slur.segments[0];
                if (seg0.tick !== undefined)
                    st = toTicks(seg0.tick);
                else if (seg0.startSegment && seg0.startSegment.tick !== undefined)
                    st = toTicks(seg0.startSegment.tick);
            } catch (_) {}
        }

        // ---------------------------
        // 4.7‑aware end tick
        // ---------------------------
        let et = 0;

        // 1) spannerTick2
        try {
            if (slur.spannerTick2 !== undefined)
                et = toTicks(slur.spannerTick2);
        } catch (_) {}

        // 2) tick2
        if (!et) {
            try {
                if (slur.tick2 !== undefined)
                    et = toTicks(slur.tick2);
            } catch (_) {}
        }

        // 3) endSegment.tick
        // Guard against mu::engraving::apiv1::Segment objects that are not usable ticks.
        if (!et) {
            try {
                if (slur.endSegment && slur.endSegment.tick !== undefined) {
                    let raw = slur.endSegment.tick;
                    // Only accept raw ticks if they are a number or have .ticks
                    if (typeof raw === "number")
                        et = raw;
                    else if (raw && raw.ticks !== undefined)
                        et = raw.ticks;
                    // Otherwise ignore – MS4.7 often returns Segment objects here
                }
            } catch (_) {}
        }

        // 4) last segment fallback
        if (!et && slur.segments && slur.segments.length > 0) {
            try {
                const segLast = slur.segments[slur.segments.length - 1];
                if (segLast.tick2 !== undefined)
                    et = toTicks(segLast.tick2);
                else if (segLast.tick !== undefined)
                    et = toTicks(segLast.tick);
                else if (segLast.endSegment && segLast.endSegment.tick !== undefined)
                    et = toTicks(segLast.endSegment.tick);
            } catch (_) {}
        }

        // ---------------------------
        // Resolve start staff
        // ---------------------------
        let sStaff = -1;
        try {
            if (slur.track !== undefined)
                sStaff = Math.floor(slur.track / 4);
        } catch (_) {}

        // fallback: spannerTrack2
        if (sStaff < 0) {
            try {
                if (slur.spannerTrack2 !== undefined)
                    sStaff = Math.floor(slur.spannerTrack2 / 4);
            } catch (_) {}
        }

        // fallback: segment[0].element.track
        if (sStaff < 0 && slur.segments && slur.segments.length > 0) {
            try {
                const seg0 = slur.segments[0];
                if (seg0.element && seg0.element.track !== undefined)
                    sStaff = Math.floor(seg0.element.track / 4);
            } catch (_) {}
        }

        // ---------------------------
        // Resolve end staff
        // ---------------------------
        let eStaff = -1;
        try {
            if (slur.spannerTrack2 !== undefined)
                eStaff = Math.floor(slur.spannerTrack2 / 4);
        } catch (_) {}

        // fallback: track for 1‑segment slur cases
        if (eStaff < 0) {
            try {
                if (slur.track !== undefined)
                    eStaff = Math.floor(slur.track / 4);
            } catch (_) {}
        }

        // fallback: end segment element
        if (eStaff < 0 && slur.segments && slur.segments.length > 0) {
            try {
                const segLast = slur.segments[slur.segments.length - 1];
                if (segLast.element && segLast.element.track !== undefined)
                    eStaff = Math.floor(segLast.element.track / 4);
            } catch (_) {}
        }

        return { st, et, sStaff, eStaff };
    }

    //
    // Option‑2 slur end resolution for MS4.7
    // 1) Reconstruct true source‑slur end (t1src) from srcChords
    // 2) Snap to next chord on target staff/voice (Option 2 behavior)
    //
    function findSourceSlurEndTick(slur, t0, srcChords, tgtStaff, voice) {

        // --- Helper: get chord tick from chord element ---
        function chordTick(ch) {
            if (!ch) return 0;
            try {
                if (ch.fraction && ch.fraction.ticks !== undefined)
                    return ch.fraction.ticks;
            } catch (_) {}
            try {
                if (ch.parent && ch.parent.tick !== undefined)
                    return ch.parent.tick;
            } catch (_) {}
            return 0;
        }

        // ============================================================
        // 1) Reconstruct TRUE source end tick (t1src)
        // ============================================================
        // MS4.7 slurs supply no endTick, so infer from the source slur span.
        // Find the last srcChord whose tick is >= t0 (start) and part of the span.
        //
        let t1src = t0;
        for (let i = 0; i < srcChords.length; i++) {
            const ch = srcChords[i];
            const tick = chordTick(ch);
            if (tick >= t0) {
                t1src = tick;      // advance end as far as chords go
            }
        }

        // t1src now equals the tick of the last source chord spanned by the slur.
        // (Example: 12480)

        // ============================================================
        // 2) Option‑2 snapping:
        // Snap to target staff’s next chord >= t1src.
        // ============================================================
        function findNextTargetChordTick(staffIdx, voice, startTick) {
            try {
                const c = curScore.newCursor();
                c.track = staffIdx * 4 + (voice - 1);
                c.rewindToTick(startTick);

                // Try exact or later ticks
                while (c.segment) {
                    const el = c.element;
                    if (el && el.type === Element.CHORD)
                        return c.tick;
                    if (!c.next()) break;
                }
            } catch (_) {}
            return null;
        }

        const snapped = findNextTargetChordTick(tgtStaff, voice, t1src);

        // If target has a chord after t1src → use it
        if (snapped !== null)
            return snapped;

        // Else fallback to raw t1src
        return t1src;
    }

    //
    // Robust anchor note search: search ±3 ticks,
    // then fallback to nearest chord.
    //
    function findAnchorNote(staff, voice, tick) {
        const c = curScore.newCursor();
        c.track = staff * 4 + (voice - 1);

        const candidates = [tick, tick - 1, tick + 1, tick - 2, tick + 2, tick - 3, tick + 3];

        for (let tt of candidates) {
            c.rewindToTick(tt);
            if (c.element && c.element.type === Element.CHORD)
                return c.element;
        }

        // find nearest chord:
        let nearest = null;
        let bestDist = 999999;

        for (let delta = -30; delta <= 30; delta++) {
            let tt = tick + delta;
            c.rewindToTick(tt);
            if (c.element && c.element.type === Element.CHORD) {
                const d = Math.abs(delta);
                if (d < bestDist) { bestDist = d; nearest = c.element; }
            }
        }

        return nearest;
    }

    function buildSlurStartMapFromSpanners(startTick, endTick, allowedMap) {
        root.slurStartByStaff = ({});
        if (!curScore || !curScore.spanners)
            return;

        const sp = curScore.spanners;
        for (let i = 0; i < sp.length; ++i) {
            const s = sp[i];
            if (!s) continue;

            // DEBUG LOG (unchanged)
            console.log("[SLURDBG] spanner[" + i + "] type:", s.type,
                        "track:", s.track,
                        "spannerTrack2:", s.spannerTrack2,
                        "segments:", (s.segments ? s.segments.length : 0));

            // ---------------------------------------------------------------------
            // FIX: Accept both Element.SLUR and Element.SLUR_SEGMENT
            // ---------------------------------------------------------------------
            let isSlur = false;
            try {
                if (typeof Element.SLUR !== "undefined" && s.type === Element.SLUR)
                    isSlur = true;
            } catch (_) {}

            try {
                if (typeof Element.SLUR_SEGMENT !== "undefined" && s.type === Element.SLUR_SEGMENT)
                    isSlur = true;
            } catch (_) {}

            if (!isSlur) {
                console.log("[SLURDBG] spanner[" + i + "] skipped: not a slur");
                continue;
            }

            // ---------------------------------------------------------------------
            // FIX: Determine tStart even when segments.length === 0
            // ---------------------------------------------------------------------
            let tStart = 0;

            // 1) spannerTick (preferred if present)
            try {
                if (s.spannerTick !== undefined)
                    tStart = fractionToTicks(s.spannerTick);
            } catch (_) {}

            // 2) tick (sometimes 4.x provides this)
            if (!tStart) {
                try {
                    if (s.tick !== undefined)
                        tStart = fractionToTicks(s.tick);
                } catch (_) {}
            }

            // 3) startSegment.tick
            if (!tStart) {
                try {
                    if (s.startSegment && s.startSegment.tick !== undefined)
                        tStart = fractionToTicks(s.startSegment.tick);
                } catch (_) {}
            }

            // 4) segments[0]
            if (!tStart && s.segments && s.segments.length > 0) {
                const seg0 = s.segments[0];
                try {
                    if (seg0.tick !== undefined)
                        tStart = fractionToTicks(seg0.tick);
                    else if (seg0.startSegment && seg0.startSegment.tick !== undefined)
                        tStart = fractionToTicks(seg0.startSegment.tick);
                } catch (_) {}
            }

            console.log("[SLURDBG] candidate slur start",
                        "i:", i,
                        "tStart:", tStart,
                        "startTick:", startTick,
                        "endTick:", endTick);

            if (!tStart) continue;
            if (tStart < startTick || tStart >= endTick)
                continue;

            // ---------------------------------------------------------------------
            // FIX: Resolve staff from multiple possible fields
            // ---------------------------------------------------------------------
            let staffIdx = -1;
            try {
                if (s.track !== undefined)
                    staffIdx = Math.floor(s.track / 4);
            } catch (_) {}

            if (staffIdx < 0) {
                try {
                    if (s.spannerTrack2 !== undefined)
                        staffIdx = Math.floor(s.spannerTrack2 / 4);
                } catch (_) {}
            }

            if (staffIdx < 0 && s.segments && s.segments.length > 0) {
                const seg0 = s.segments[0];
                try {
                    if (seg0.element && seg0.element.track !== undefined)
                        staffIdx = Math.floor(seg0.element.track / 4);
                } catch (_) {}
            }

            // FINAL fallback
            if (staffIdx < 0)
                staffIdx = "_any";

            console.log("[SLURDBG] slur @ tStart:", tStart,
                        "resolved staff:", staffIdx);

            // ---------------------------------------------------------------------
            // Allowed-staff filtering
            // ---------------------------------------------------------------------
            if (allowedMap &&
                    staffIdx >= 0 &&
                    allowedMap.hasOwnProperty(staffIdx) &&
                    !allowedMap[staffIdx])
                continue;

            const key = String(staffIdx);
            if (!root.slurStartByStaff[key])
                root.slurStartByStaff[key] = ({});

            root.slurStartByStaff[key][tStart] = true;

            console.log("[SLURDBG] ✅ RECORDED slur start: staff", key, "tick", tStart);
        }
    }


    function slurStartAtStaffTick(srcStaff, tick) {
        // Helper to test presence safely
        function hasAt(staffKey, t) {
            try {
                return !!(
                            root.slurStartByStaff &&
                            root.slurStartByStaff[staffKey] &&
                            root.slurStartByStaff[staffKey][t]
                            );
            } catch (e) {
                return false;
            }
        }

        // Keys we should probe:
        // 1. The exact staff index as a string   → "0", "1", "2", ...
        // 2. The fallback bucket                 → "_any"
        const staffKey = String(srcStaff);

        // Candidate ticks to test, with ±1 wiggle
        const candidates = [tick, tick - 1, tick + 1];

        // Check explicit staff assignment first
        for (let t of candidates) {
            if (hasAt(staffKey, t)) {
                console.log("[SLURDBG] probe slurStartAtStaffTick",
                            "staff=", srcStaff,
                            "tick=", tick,
                            "result=true (staffKey:", staffKey, ")");
                return true;
            }
        }

        // Check wildcard slurs ("_any") second
        for (let t of candidates) {
            if (hasAt("_any", t)) {
                console.log("[SLURDBG] probe slurStartAtStaffTick",
                            "staff=", srcStaff,
                            "tick=", tick,
                            "result=true (staffKey:_any)");
                return true;
            }
        }

        // Nothing matched
        console.log("[SLURDBG] probe slurStartAtStaffTick",
                    "staff=", srcStaff,
                    "tick=", tick,
                    "result=false");
        return false;
    }



    // From the preset rows for a staff, return unique voices (1..4) that are active.
    function activeVoicesFromRows(rows) {
        var seen = {}, out = [];
        for (var i = 0; i < rows.length && i < 8; ++i) {
            var r = rows[i];
            if (!r || !r.active) continue;
            var v = clampInt(Number(r.voice || 1), 1, 4);
            if (!seen[v]) { seen[v] = true; out.push(v); }
        }
        return out;
    }

    function queueSlursForOrchestration(srcStaff, srcChords) {
        const uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
            return [];

        const p = presets[uiRef.selectedIndex];
        if (!p || !p.noteRowsByStaff)
            return [];

        const sp = curScore.spanners;
        let queued = [];

        console.log("[SLURDBG] ==== QUEUE SLURS BEGIN ====");
        console.log("[SLURDBG] srcStaff =", srcStaff);
        console.log("[SLURDBG] srcChordCount =", srcChords.length);

        for (let i = 0; i < sp.length; ++i) {
            let slur = sp[i];
            console.log("[SLURDBG] queue pass slur index", i,
                        "type:", slur ? slur.type : null,
                        "track:", slur ? slur.track : null);

            if (!slur)
                continue;

            // Identify slur-type spanners robustly
            let isSlur = false;
            try { if (typeof Element.SLUR !== "undefined" && slur.type === Element.SLUR) isSlur = true; } catch (_) {}
            try { if (typeof Element.SLUR_SEGMENT !== "undefined" && slur.type === Element.SLUR_SEGMENT) isSlur = true; } catch (_) {}

            if (!isSlur) {
                console.log("[SLURDBG]   not a slur → skip");
                continue;
            }

            console.log("[SLURDBG]   slur accepted into queue pass:", i);

            // Extract raw slur info
            let info = slurInfo(slur);
            let t0 = info.st;
            let t1src = info.et;   // (may be 0 in MS4.7)

            console.log("[SLURDBG]   slurInfo:",
                        "t0=", info.st,
                        "t1=", info.et,
                        "sStaff=", info.sStaff,
                        "eStaff=", info.eStaff);

            let present = slurStartAtStaffTick(srcStaff, t0);

            try {
                const staffKey = String(srcStaff);
                console.log("[SLURDBG]   slurStartByStaff keys:", Object.keys(root.slurStartByStaff));
                console.log("[SLURDBG]   bucket for srcStaff =", staffKey, ":", root.slurStartByStaff[staffKey]);
                console.log("[SLURDBG]   wildcard bucket (_any):", root.slurStartByStaff["_any"]);
            } catch (eMap) {}

            console.log("[SLURDBG]   slurStartAtStaffTick returned:", present);

            if (!present) {
                console.log("[SLURDBG]   ----- SLUR REJECTED BEFORE DESTINATION LOOP -----");
                continue;
            }

            console.log("[SLURDBG]   ✅ ACCEPTED slur for queuing — checking destination rows…");

            // ======================================================
            // ✅ Iterate destination staves — THIS IS WHERE t1 BELONGS
            // ======================================================
            for (let sidKey in p.noteRowsByStaff) {
                if (!p.noteRowsByStaff.hasOwnProperty(sidKey))
                    continue;

                const dstStaff = parseInt(sidKey, 10);
                if (isNaN(dstStaff) || dstStaff < 0)
                    continue;

                const rows = p.noteRowsByStaff[sidKey];

                console.log("[SLURDBG]     check dstStaff:", sidKey,
                            "rows valid?", Array.isArray(rows),
                            "anyActive?", (function() {
                                if (!Array.isArray(rows)) return false;
                                for (let r of rows) if (r && r.active) return true;
                                return false;
                            })());

                if (!Array.isArray(rows)) {
                    console.log("[SLURDBG]     ⚠️ Skipping staff", sidKey, "because rows is not an array:", rows);
                    continue;
                }

                // Per-voice (unique) slur generation
                const voices = activeVoicesFromRows(rows);
                for (let vi = 0; vi < voices.length; ++vi) {
                    const voice = voices[vi];
                    const t1 = findSourceSlurEndTick(slur, t0, srcChords, dstStaff, voice);
                    const item = { tgtStaff: dstStaff, voice: voice, t0: t0, t1: t1 };
                    console.log("[SLURDBG] ✅ QUEUED slur (unique voice) dstStaff:", dstStaff, "voice:", voice, "t0:", t0, "t1:", t1);
                    queued.push(item);
                }
            }
        }

        console.log("[SLURDBG] ==== QUEUE SLURS END ====");
        console.log("[SLURDBG] total queued slurs:", queued.length);

        return queued;
    }

    // Apply a specific preset card (by index) to the current selection without
    // changing the UI selection. Mirrors applyCurrentPresetToSelection().
    function applyPresetIndexToSelection(index) {
        if (!curScore || !curScore.selection) return;
        if (!(index >= 0 && index < presets.length)) return;

        var p = presets[index];
        if (!p || !p.noteRowsByStaff) return;

        var pendingTies = [];
        var pendingTiesSeen = {};
        var pendingSymbols = [];

        // ✅ Get notation filter (slurs are ignored in this mode)
        var nf = (p.notationFilter ? p.notationFilter : defaultNotationFilter());

        // ✅ Determine source staff (slur-based detection allowed here)
        var srcStaff = -1;

        if (curScore.spanners && curScore.spanners.length > 0) {
            for (let s of curScore.spanners) {
                if (!s) continue;
                let isSlur = false;
                try { if (s.type === Element.SLUR) isSlur = true; } catch(_) {}
                try { if (s.type === Element.SLUR_SEGMENT) isSlur = true; } catch(_) {}
                if (!isSlur) continue;

                let stf = -1;
                try { if (s.startElement && s.startElement.staffIdx !== undefined) stf = s.startElement.staffIdx; } catch(_) {}
                try { if (stf < 0 && s.track !== undefined) stf = Math.floor(s.track / 4); } catch(_) {}

                if (stf >= 0) {
                    srcStaff = stf;
                    break;
                }
            }
        }

        if (srcStaff < 0) {
            if (curScore.selection.elements.length > 0) {
                for (let el of curScore.selection.elements) {
                    let ch = (el && el.parent && el.parent.staffIdx !== undefined) ? el.parent : el;
                    if (ch && ch.staffIdx !== undefined) {
                        srcStaff = ch.staffIdx;
                        break;
                    }
                }
            }
        }

        if (!(srcStaff >= 0)) return;

        let srcChords = collectSourceChordsInSelectionForStaff(srcStaff);
        if (!srcChords.length) return;

        // ✅ Pure note and symbol copying (no slurs)
        curScore.startCmd(qsTr("Orchestrator apply preset (index): %1").arg(String(p.name ?? qsTr("Preset"))));

        try {
            for (let chord of srcChords) {
                let frac = chord.fraction;
                let dur = chord.actualDuration;
                let num = dur?.numerator ?? 1;
                let den = dur?.denominator ?? 4;

                for (let sidKey in p.noteRowsByStaff) {
                    if (!p.noteRowsByStaff.hasOwnProperty(sidKey)) continue;

                    let tgtStaff = parseInt(sidKey, 10);
                    if (isNaN(tgtStaff) || tgtStaff < 0) continue;

                    let rows = p.noteRowsByStaff[sidKey] || [];
                    let anyActive = rows.some(r => r && r.active);
                    if (!anyActive) continue;

                    let pitchesByVoice = {};
                    let tiesByVoice = {};

                    for (let row = 0; row < rows.length && row < 8; ++row) {
                        let spec = rows[row];
                        if (!spec || !spec.active) continue;

                        let srcPitch = pitchForRowFromChord(chord, row);
                        if (srcPitch === null || srcPitch === undefined) continue;

                        let destPitch = clampInt(srcPitch + Number(spec.offset ?? 0), 0, 127);
                        let voice = clampInt(Number(spec.voice ?? 1), 1, 4);
                        let vKey = String(voice);

                        if (!pitchesByVoice[vKey]) pitchesByVoice[vKey] = [];
                        if (!pitchesByVoice[vKey].includes(destPitch))
                            pitchesByVoice[vKey].push(destPitch);

                        if (nf.ties && sourceHasTieForward(chord, srcPitch)) {
                            if (!tiesByVoice[vKey]) tiesByVoice[vKey] = [];
                            if (!tiesByVoice[vKey].includes(destPitch))
                                tiesByVoice[vKey].push(destPitch);
                        }
                    }

                    for (let vKey in pitchesByVoice) {
                        let voice = parseInt(vKey, 10);
                        let list = pitchesByVoice[vKey];

                        let c2 = curScore.newCursor();
                        c2.track = tgtStaff * 4 + (voice - 1);
                        c2.rewindToFraction(frac);
                        c2.setDuration(num, den);

                        let elNow = c2.element;
                        if (!elNow || (elNow.type !== Element.CHORD && elNow.type !== Element.REST))
                            ensureWritableSlot(c2, num, den);

                        c2.rewindToFraction(frac);
                        let addToChord = (c2.element && c2.element.type === Element.CHORD);

                        try { c2.addNote(list[0], addToChord); } catch(_) {}
                        for (let k = 1; k < list.length; ++k) {
                            c2.rewindToFraction(frac);
                            try { c2.addNote(list[k], true); } catch(_) {}
                        }

                        let tTick2 = frac?.ticks ?? 0;

                        if (nf.ties && tiesByVoice[vKey]) {
                            for (let dp of tiesByVoice[vKey]) {
                                let key = `${tgtStaff}:${voice}:${tTick2}:${dp}`;
                                if (!pendingTiesSeen[key]) {
                                    pendingTiesSeen[key] = true;
                                    pendingTies.push({
                                                         tgtStaff: tgtStaff,
                                                         voice: voice,
                                                         tick: tTick2,
                                                         pitch: dp
                                                     });
                                }
                            }
                        }

                        // ✅ Symbol copying preserved
                        if (nf.articulations || nf.ornaments) {
                            let queuedSymbolKeys = {};

                            if (chord) {
                                if (nf.articulations && chord.articulations) {
                                    for (let a of chord.articulations) {
                                        if (!a) continue;
                                        let sub = "";
                                        try { sub = a.subtypeName ? String(a.subtypeName()) : ""; } catch(_) {}
                                        let key = `${a.type}\n${sub}\nchord`;
                                        if (!queuedSymbolKeys[key]) {
                                            queuedSymbolKeys[key] = true;
                                            pendingSymbols.push({
                                                                    kind: 'chord',
                                                                    tgtStaff: tgtStaff,
                                                                    voice: voice,
                                                                    tick: tTick2,
                                                                    src: a,
                                                                    srcStaff: srcStaff
                                                                });
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch(e) {
            curScore.endCmd(true);
            console.log("[Orchestrator] ERROR:", String(e));
            return;
        }

        curScore.endCmd();

        if (nf.ties && pendingTies.length > 0) {
            for (let T of pendingTies) {
                let nStart = findNoteAt(T.tgtStaff, T.voice, T.tick, T.pitch);
                if (!nStart) continue;
                try { if (nStart.tieForward) continue; } catch(_) {}
                withSingleSelection(nStart, "chord-tie");
            }
        }

        if ((nf.articulations || nf.ornaments) && pendingSymbols.length > 0) {
            processPendingSymbolsAsync(pendingSymbols, 0);
        }
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

        // Attach dynamic engine functions to dynamicAPI object
        dynamicAPI.detectDynamics   = detectDynamics;
        dynamicAPI.createDynamic    = createDynamic;
        dynamicAPI.createHairpin    = createHairpin;
        dynamicAPI.addDynamicByBeat = addDynamicByBeat;

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

                                        // 1) SETTINGS MODE: keep editing behavior (select card, no execution)
                                        onPressed: function (mouse) {
                                            if (root.settingsOpen) {
                                                rootUI.selectedIndex = model.index;     // select for editing
                                            }
                                            ui.tooltip.hide(root, true);
                                        }

                                        // 2) NORMAL MODE: execute preset with slur-aware flow, without persisting selection
                                        onClicked: {
                                            if (!root.settingsOpen) {
                                                // Temporarily select this card so applyCurrentPresetToSelection() uses it
                                                var prevSel = rootUI.selectedIndex;
                                                var prevSuppress = root.suppressApplyPreset;

                                                root.suppressApplyPreset = true;        // avoid UI side-effects while flipping selection
                                                rootUI.selectedIndex = model.index;
                                                root.suppressApplyPreset = prevSuppress;

                                                // Slur-aware engine (builds StartMap BEFORE note-writing)
                                                root.applyCurrentPresetToSelection();

                                                // Restore "no persistent selection" (same UX as your original code)
                                                rootUI.selectedIndex = -1;
                                                return;
                                            }

                                            // If settingsOpen, do nothing here; onPressed already selected the card for editing.
                                        }

                                        preventStealing: true
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
