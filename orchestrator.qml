//===============================================================================
// Orchestrator - Preset system to quickly orchestrate sketches in MuseScore
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
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import FileIO 3.0
import MuseApi.Interactive 1.0
import MuseApi.Log 1.0
import Muse.Ui
import Muse.UiComponents
import MuseScore 3.0

pragma Singleton

MuseScore {
    id: root

    title: qsTr("Orchestrator")
    description: qsTr("Preset system to quickly orchestrate sketches in MuseScore")
    categoryCode: "composing-arranging-tools"
    thumbnailName: "orchestrator.png"
    version: "0.2.9"

    //--------------------------------------------------------------------------------
    // Log Engine
    //--------------------------------------------------------------------------------

    property string logLevel: "debug" // "normal" | "verbose" | "debug"
    property string tag: root.title.toUpperCase()

    function __canLog(level) {
        var order = ({ normal: 0, verbose: 1, debug: 2 })
        var cur = order[String(root.logLevel || "debug")]
        var want = order[String(level || "normal")]
        if (cur === undefined) cur = 2
        if (want === undefined) want = 0
        return cur >= want
    }

    function __logInfo(message)  { if (__canLog("normal")) Log.info(tag, String(message)) }
    function __logWarn(message)  { if (__canLog("verbose")) Log.warn(tag, String(message)) }
    function __logDebug(message) { if (__canLog("debug")) Log.debug(tag, String(message)) }
    function __logError(message) { Log.error(tag, String(message)) }  // always show errors

    //--------------------------------------------------------------------------------
    // JSON Preset Array & UI Engine
    //--------------------------------------------------------------------------------

    property int baseWidth: 300
    property bool settingsOpen: false
    property bool gridView: false
    property bool usedInstView: false
    property var duplicateStaffMap: ({})
    property var orchestratorWin: null
    property var selectedStaff: ({})
    property int selectedCountProp: 0
    property int lastAnchorIndex: -1
    property int currentStaffIdx: -1
    property bool liveCommitEnabled: true
    property var pendingOverwrite: null

    // Theme
    property bool isDarkTheme: (function () {
        if (ui && ui.theme && ui.theme.isDark !== undefined) {
            const v = ui.theme.isDark
            return (typeof v === "function") ? !!v() : !!v
        }
    })

    // Store preset JSON via QML Settings (on-disk per user config)
    Settings {
        id: ocPrefs
        category: root.title
        property string presetsJSON: ""
        property bool lastSettingsOpen: false
        property int  lastWindowHeight: 0
        property bool lastGridView: false
        property int  lastSelectedIndex: -1
        property int  lastWindowX: 0
        property int  lastWindowY: 0
    }

    FileIO {
        id: presetCollectionFile
        onError: function(msg) {
            root.__logError("Preset collection file error: " + String(msg))
        }
    }

    // In-memory presets array
    property var presets: ([])
    property bool suppressApplyPreset: false
    property bool creatingNewPreset: false
    property var activeScoreRegistry: ({
                                           entries: [],
                                           byStableKey: ({})
                                       })

    // Persist 1-across vs 2-across preset layout
    onGridViewChanged: {
        try {
            ocPrefs.lastGridView = !!gridView;
            if (ocPrefs.sync) ocPrefs.sync();
        } catch (e) {}
    }

    // Persist Settings panel open/closed
    onSettingsOpenChanged: {
        try {
            ocPrefs.lastSettingsOpen = settingsOpen;
            if (ocPrefs.sync) ocPrefs.sync();
        } catch (e) {}

        if (settingsOpen) {
            buildStaffListModel()
            refreshStaffActiveRows()
            refreshPresetsListModel()
            remapSelectedStaffByStableKey()
            refreshDuplicateStaffMap()
        } else {
            duplicateStaffMap = ({})
        }
    }

    property int pitchOffsetMax: 36
    readonly property int pitchCenterIndex: pitchOffsetMax

    // Pitch offset <-> dropdown index mapping (0..72, 36 == 0 semitones)
    function pitchValueToIndex(v) {
        var n = Number(v) || 0
        if (n > root.pitchOffsetMax) n = root.pitchOffsetMax
        if (n < -root.pitchOffsetMax) n = -root.pitchOffsetMax
        if (n > 0) return root.pitchCenterIndex - n
        if (n === 0) return root.pitchCenterIndex
        return root.pitchCenterIndex + (-n)
    }

    function pitchIndexToValue(ix) {
        var i = Number(ix)
        if (isNaN(i)) i = root.pitchCenterIndex
        if (i < 0) i = 0
        if (i > (root.pitchOffsetMax * 2)) i = root.pitchOffsetMax * 2
        if (i < root.pitchCenterIndex) return root.pitchCenterIndex - i
        if (i === root.pitchCenterIndex) return 0
        return -(i - root.pitchCenterIndex)
    }

    function __instrumentAtTickForStaff(staffIdx, tick) {
        var p = partForStaff(staffIdx)
        if (!p)
            return null
        var t = Number(tick ?? 0)
        var inst = null
        try {
            if (p.instrumentAtTick)
                inst = p.instrumentAtTick(t)
        } catch (e0) {}
        if (!inst) {
            try {
                if (p.instruments && p.instruments.length)
                    inst = p.instruments[0]
            } catch (e1) {}
        }
        return inst
    }

    function defaultRows() {
        var rows = []
        for (var i = 0; i < 8; ++i)
            rows.push({ active: false, offset: 0, voice: 0 })
        return rows
    }

    function hasAnyActiveRows(rows) {
        if (!rows || !rows.length) return false;
        for (var i = 0; i < rows.length; ++i) {
            if (rows[i] && rows[i].active) return true;
        }
        return false;
    }

    function staffHasActiveRowsInPreset(presetObj, staffIdx) {
        if (!presetObj)
            return false;
        var stableKey = stableKeyForStaff(staffIdx, 0);
        if (!stableKey.length)
            return false;
        var rows = presetRowsForStableKey(presetObj, stableKey);
        return hasAnyActiveRows(rows || []);
    }

    function staffHasActiveRowsInCurrentPreset(staffIdx) {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
            return false;
        return staffHasActiveRowsInPreset(presets[uiRef.selectedIndex], staffIdx);
    }

    function isStaffRowVisible(rowIndex) {
        if (rowIndex < 0 || rowIndex >= staffListModel.count)
            return false;
        if (!root.usedInstView)
            return true;
        var item = staffListModel.get(rowIndex);
        return !!item && staffHasActiveRowsInCurrentPreset(item.idx);
    }

    function firstVisibleStaffRowIndex() {
        for (var i = 0; i < staffListModel.count; ++i) {
            if (isStaffRowVisible(i))
                return i;
        }
        return -1;
    }

    function lastVisibleStaffRowIndex() {
        for (var i = staffListModel.count - 1; i >= 0; --i) {
            if (isStaffRowVisible(i))
                return i;
        }
        return -1;
    }

    function nextVisibleStaffRowIndex(fromRow, step) {
        var dir = (step < 0) ? -1 : 1;
        if (staffListModel.count <= 0)
            return -1;

        var row = Number(fromRow);
        if (isNaN(row))
            row = -1;

        if (row < 0 || row >= staffListModel.count)
            return dir > 0 ? firstVisibleStaffRowIndex() : lastVisibleStaffRowIndex();

        row += dir;
        while (row >= 0 && row < staffListModel.count) {
            if (isStaffRowVisible(row))
                return row;
            row += dir;
        }
        return -1;
    }

    function pruneSelectionToVisibleStaffRows() {
        if (!root.usedInstView)
            return;

        var ns = ({});
        for (var k in selectedStaff) {
            if (!selectedStaff.hasOwnProperty(k) || !selectedStaff[k])
                continue;
            var sid = Number(k);
            if (staffHasActiveRowsInCurrentPreset(sid))
                ns[k] = true;
        }
        selectedStaff = ns;
        bumpSelection();
    }

    onUsedInstViewChanged: {
        var sl = orchestratorWin ? orchestratorWin.staffListRef : null;
        if (!sl)
            return;

        refreshDuplicateStaffMap()
        refreshStaffActiveRows()

        if (root.usedInstView) {
            pruneSelectionToVisibleStaffRows();
            if (sl.currentIndex >= 0 && !isStaffRowVisible(sl.currentIndex))
                sl.currentIndex = firstVisibleStaffRowIndex();
        }
    }

    function newPresetObject(name) {
        return {
            id: String(Date.now()) + "-" + Math.random().toString(16).slice(2),
            name: String(name ?? qsTr("New Preset")),
            backgroundColor: "",
            noteRowsByStableKey: {}
        }
    }

    function presetRowsMap(presetObj) {
        if (!presetObj || !presetObj.noteRowsByStableKey)
            return ({})
        return presetObj.noteRowsByStableKey
    }

    function presetEntryForStableKey(presetObj, stableKey) {
        if (!presetObj || !presetObj.noteRowsByStableKey)
            return null
        var entry = presetObj.noteRowsByStableKey[String(stableKey)]
        return entry || null
    }

    function presetRowsForStableKey(presetObj, stableKey) {
        var entry = presetEntryForStableKey(presetObj, stableKey)
        if (!entry || !entry.rows)
            return []
        return entry.rows
    }

    function presetInstLongNameForStableKey(presetObj, stableKey) {
        var entry = presetEntryForStableKey(presetObj, stableKey)
        if (!entry)
            return ""
        return String(entry.instLongName ?? "")
    }

    function presetActiveStableKeys(presetObj) {
        var out = []
        var map = presetRowsMap(presetObj)
        for (var stableKey in map) {
            if (!map.hasOwnProperty(stableKey))
                continue
            var rows = presetRowsForStableKey(presetObj, stableKey)
            if (hasAnyActiveRows(rows))
                out.push(String(stableKey))
        }

        var scoreOrder = activeScoreStableKeyOrder();
        out.sort(function (a, b) {
            var ia = scoreOrder.indexOf(a);
            var ib = scoreOrder.indexOf(b);
            if (ia === -1 && ib === -1) return a < b ? -1 : 1; // fallback
            if (ia === -1) return 1;
            if (ib === -1) return -1;
            return ia - ib;
        })

        return out
    }

    function presetInstLongNamesFromStableKeys(presetObj, arr) {
        if (!arr || !arr.length)
            return ""
        var names = []
        for (var i = 0; i < arr.length; ++i) {
            var nm = presetInstLongNameForStableKey(presetObj, arr[i])
            if (!nm.length)
                nm = qsTr("Unknown instrument")
            names.push(nm)
        }
        return names.join(", ")
    }

    function rebuildActiveScoreRegistry(tick) {
        var registry = {
            entries: [],
            byStableKey: ({})
        }

        if (!curScore || !curScore.parts) {
            activeScoreRegistry = registry
            return registry
        }

        var t = Number(tick ?? 0)
        for (var pIdx = 0; pIdx < curScore.parts.length; ++pIdx) {
            var p = curScore.parts[pIdx]
            if (!p)
                continue

            var baseStaff = Math.floor(p.startTrack / 4)
            var numStaves = Math.floor((p.endTrack - p.startTrack) / 4)
            for (var sOff = 0; sOff < numStaves; ++sOff) {
                var staffIdx = baseStaff + sOff
                var stableKey = stableKeyForStaff(staffIdx, t)
                if (!stableKey.length) {
                    __logWarn("activeScoreRegistry: skipped staffIdx=" + staffIdx + " reason=empty stableKey")
                    continue
                }

                var entry = {
                    stableKey: stableKey,
                    musicXmlId: musicXmlIdForStaff(staffIdx, t),
                    normalizedInstLongName: normalizeInstLongName(instLongNameForStaff(staffIdx, t)),
                    staffOffsetWithinInst: sOff,
                    staffIdx: staffIdx
                }

                registry.entries.push(entry)

                if (!registry.byStableKey[stableKey])
                    registry.byStableKey[stableKey] = []
                registry.byStableKey[stableKey].push(staffIdx)
            }
        }

        activeScoreRegistry = registry
        __logDebug("activeScoreRegistry " + activeScoreRegistry.entries.length + " entries:");
        for (var i = 0; i < activeScoreRegistry.entries.length; ++i) {
            __logDebug(formatRegistryEntryInline(activeScoreRegistry.entries[i], 1));
        }
        return registry
    }

    function activeScoreRegistryStaffIdxsForStableKey(stableKey) {
        if (!activeScoreRegistry || !activeScoreRegistry.byStableKey)
            return []
        var arr = activeScoreRegistry.byStableKey[String(stableKey)] || []
        return arr.slice(0)
    }

    function resolveStableKeyInActiveScore(stableKey) {
        var key = String(stableKey ?? "")
        var matches = activeScoreRegistryStaffIdxsForStableKey(key)

        __logDebug(
                    "resolveStableKeyInActiveScore key=" + String(stableKey) +
                    " matches=" + JSON.stringify(activeScoreRegistryStaffIdxsForStableKey(stableKey))
                    );

        if (!key.length || matches.length === 0) {
            return {
                status: "MISSING",
                stableKey: key
            }
        }

        if (matches.length === 1) {
            return {
                status: "RESOLVED",
                stableKey: key,
                staffIdx: Number(matches[0])
            }
        }

        return {
            status: "DUPLICATE",
            stableKey: key,
            candidateStaffIdxs: matches.slice(0)
        }
    }

    function activeScoreStableKeyOrder() {
        var order = [];
        if (!activeScoreRegistry || !activeScoreRegistry.entries) return order;

        var seen = {};
        for (var i = 0; i < activeScoreRegistry.entries.length; ++i) {
            var k = activeScoreRegistry.entries[i].stableKey;
            if (!seen[k]) {
                seen[k] = true;
                order.push(k);
            }
        }
        return order;
    }

    function duplicateStaffIdxsForPreset(presetObj) {
        var out = {}

        if (!presetObj || !presetObj.noteRowsByStableKey)
            return out

        var info = __resolvedAssignmentsForPresetInActiveScore(presetObj)

        if (!info || !info.duplicateStableKeys)
            return out

        for (var i = 0; i < info.duplicateStableKeys.length; ++i) {
            var d = info.duplicateStableKeys[i]
            for (var j = 0; j < d.staffIdxs.length; ++j) {
                out[d.staffIdxs[j]] = true
            }
        }

        return out
    }

    function refreshDuplicateStaffMap() {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null
        if (!root.settingsOpen || !uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length) {
            duplicateStaffMap = ({})
            return
        }
        duplicateStaffMap = duplicateStaffIdxsForPreset(presets[uiRef.selectedIndex])
    }

    function getSelectedStaffArray() {
        var out = []
        for (var k in selectedStaff) {
            if (selectedStaff.hasOwnProperty(k) && selectedStaff[k]) out.push(Number(k))
        }
        out.sort(function(a,b){return a-b})
        return out
    }

    function showDuplicateStableKeyModal(dupes) {
        var lines = []

        for (var i = 0; i < dupes.length; ++i) {
            var d = dupes[i]
            var staffNames = []
            for (var j = 0; j < d.staffIdxs.length; ++j) {
                staffNames.push(qsTr("Staff %1").arg(d.staffIdxs[j] + 1))
            }
            lines.push(d.instName + ": " + staffNames.join(", "))
        }

        Interactive.info(
                    qsTr("Duplicate instruments detected."),
                    qsTr("A target instrument occurs multiple times in the score.\n") +
                    qsTr("Remove the duplicate or change its name.\n\n") +
                    lines.join("\n"),
                    [qsTr("OK")]
                    )
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

    // In-memory presets
    function loadPresetsFromSettings() {
        try {
            var s = String(ocPrefs.presetsJSON || "")
            var parsed = s.length ? JSON.parse(s) : []
            if (!parsed || !parsed.length) {
                parsed = []
            }
            presets = parsed
            __logDebug("ocPrefs presets count: " + presets.length)
            logPrettyPresets("ocPrefs presets:", presets)
        } catch (e) {
            __logDebug("Failed to parse ocPrefs.presetsJSON: " + e)
            presets = []
        }
        refreshPresetsListModel()
        refreshStaffActiveRows()
    }

    function savePresetsToSettings() {
        try {
            ocPrefs.presetsJSON = JSON.stringify(presets, null, 2)
            if (ocPrefs.sync) { try { ocPrefs.sync() } catch (e2) {} }
        } catch (e) {
            __logError("Failed to save presets: " + String(e))
        }
    }

    function presetCollectionFileUrlToLocalPath(fileUrl) {
        var s = String(fileUrl === undefined || fileUrl === null ? "" : fileUrl)
        if (!s.length)
            return ""
        try {
            s = decodeURIComponent(s)
        } catch (e) {}
        s = s.replace(/^file:\/\/\/([A-Za-z]:\/.*)$/, "$1")
        s = s.replace(/^file:\/\//, "")
        return s
    }

    function normalizePresetCollectionSavePath(localPath) {
        var path = String(localPath ?? "").trim()
        if (!path.length)
            return ""
        if (/\.json$/i.test(path))
            return path
        return path + ".json"
    }

    function clonePresetRowsMapForCollection(noteRowsByStableKey) {
        var out = {}
        if (!noteRowsByStableKey)
            return out
        for (var stableKey in noteRowsByStableKey) {
            if (!noteRowsByStableKey.hasOwnProperty(stableKey))
                continue
            var srcEntry = noteRowsByStableKey[stableKey]
            if (!srcEntry)
                continue
            out[String(stableKey)] = {
                instLongName: String(srcEntry.instLongName ?? ""),
                rows: __deepCloneRowsArray(srcEntry.rows || [])
            }
        }
        return out
    }

    function sanitizePresetForCollection(rawPreset) {
        var raw = rawPreset || {}
        var sanitizedId = String(raw.id ?? "").trim()
        if (!sanitizedId.length)
            return null
        return {
            id: sanitizedId,
            name: String(raw.name ?? qsTr("New Preset")),
            backgroundColor: String(raw.backgroundColor ?? ""),
            noteRowsByStableKey: clonePresetRowsMapForCollection(raw.noteRowsByStableKey || {})
        }
    }

    function buildPresetCollectionDocument() {
        var doc = {
            schema: "orchestrator-preset-collection",
            schemaVersion: 1,
            pluginName: String(root.title),
            pluginVersion: String(root.version),
            presets: []
        }
        for (var i = 0; i < presets.length; ++i) {
            var sanitized = sanitizePresetForCollection(presets[i])
            if (sanitized)
                doc.presets.push(sanitized)
        }
        return doc
    }

    function parsePresetCollectionText(text) {
        var raw = JSON.parse(String(text ?? ""))
        if (Array.isArray(raw)) {
            return {
                schema: "orchestrator-preset-collection",
                schemaVersion: 1,
                presets: raw
            }
        }
        if (!raw || typeof raw !== "object" || !Array.isArray(raw.presets)) {
            throw new Error("Preset collection file does not contain a presets array.")
        }
        return raw
    }

    function mergePresetCollectionDocument(doc, sourcePath) {
        var existingIds = {}
        for (var i = 0; i < presets.length; ++i) {
            var existingId = String((presets[i] && presets[i].id) ?? "").trim()
            if (existingId.length)
                existingIds[existingId] = true
        }

        var incoming = (doc && Array.isArray(doc.presets)) ? doc.presets : []
        var added = 0
        var skipped = 0
        var invalid = 0

        for (var j = 0; j < incoming.length; ++j) {
            var sanitized = sanitizePresetForCollection(incoming[j])
            if (!sanitized) {
                invalid += 1
                continue
            }
            if (existingIds[sanitized.id]) {
                skipped += 1
                continue
            }
            presets.push(sanitized)
            existingIds[sanitized.id] = true
            added += 1
        }

        notifyPresetsMutated()
        refreshPresetsListModel()
        refreshStaffActiveRows()
        savePresetsToSettings()

        try {
            ocPrefs.lastPresetCollectionPath = String(sourcePath ?? "")
            if (ocPrefs.sync) ocPrefs.sync()
        } catch (e0) {}

        Interactive.info(
                    qsTr("Preset file loaded."),
                    qsTr("Total presets in file: %1\nAdded: %2\nSkipped (duplicate IDs): %3\nInvalid: %4")
                    .arg(incoming.length)
                    .arg(added)
                    .arg(skipped)
                    .arg(invalid)
                    )

        return {
            total: incoming.length,
            added: added,
            skipped: skipped,
            invalid: invalid
        }
    }

    function loadPresetCollectionFromPath(localPath) {
        __logInfo("loadPresetCollectionFromPath entry localPath=" + String(localPath))
        var path = String(localPath ?? "").trim()
        if (!path.length)
            return false

        presetCollectionFile.source = path

        var text = ""
        try {
            text = presetCollectionFile.read()
        } catch (e1) {
            __logError("Load preset collection read failed: " + String(e1))
            Interactive.error(
                        qsTr("Preset file load failed."),
                        qsTr("The file could not be read.\n%1").arg(path)
                        )
            return false
        }

        try {
            var doc = parsePresetCollectionText(text)
            mergePresetCollectionDocument(doc, path)
            return true
        } catch (e2) {
            __logError("Load preset collection parse/merge failed: " + String(e2))
            Interactive.error(
                        qsTr("Preset file load failed."),
                        qsTr("The file is not a valid preset collection.\n%1").arg(String(e2))
                        )
            return false
        }
    }

    function savePresetCollectionToPath(localPath) {
        __logInfo("savePresetCollectionToPath entry localPath=" + String(localPath))
        var path = normalizePresetCollectionSavePath(localPath)
        if (!path.length)
            return false
        var doc = buildPresetCollectionDocument()
        var text = JSON.stringify(doc, null, 2)
        presetCollectionFile.source = path
        var ok = false
        try {
            ok = !!presetCollectionFile.write(text)
        } catch (e3) {
            ok = false
            __logError("Save preset collection write failed: " + String(e3))
        }

        if (!ok) {
            Interactive.error(
                        qsTr("Preset file save failed."),
                        qsTr("The file could not be written. MuseScore's plugin API may block writing outside allowed directories. Save the file inside the MuseScore4 folder.\n\nFailed:\n%1").arg(path)
                        )
            return false
        }

        try {
            ocPrefs.lastPresetCollectionPath = path
            if (ocPrefs.sync) ocPrefs.sync()
        } catch (e4) {}

        Interactive.info(
                    qsTr("Preset file saved."),
                    qsTr("%1 presets were written to:\n%2")
                    .arg(doc.presets.length)
                    .arg(path)
                    )
        return true
    }

    function openPresetLoadDialog() {
        presetLoadDialog.open()
    }

    function openPresetSaveDialog() {
        presetSaveDialog.open()
    }

    FileDialog {
        id: presetLoadDialog
        type: FileDialog.Load
        title: qsTr("Load preset collection")
        folder: ""
        onAccepted: {
            var localPath = String(filePath ?? "").trim()
            root.__logInfo("presetLoadDialog accepted filePath=" + localPath)
            if (localPath.length)
                root.loadPresetCollectionFromPath(localPath)
        }
        onRejected: {
            root.__logInfo("presetLoadDialog rejected")
        }
    }


    FileDialog {
        id: presetSaveDialog
        type: FileDialog.Save
        title: qsTr("Save preset collection")
        folder: ""
        onAccepted: {
            var localPath = String(filePath ?? "").trim()
            root.__logInfo("presetSaveDialog accepted filePath=" + localPath)
            if (localPath.length)
                root.savePresetCollectionToPath(localPath)
        }
        onRejected: {
            root.__logInfo("presetSaveDialog rejected")
        }
    }

    function notifyPresetsMutated() {
        // Reassign to a fresh array reference so QML bindings re-evaluate.
        presets = presets.slice(0);
    }

    function isInlineScalarForLog(value) {
        if (value === null || value === undefined)
            return true

        var t = typeof value
        return t === "string" || t === "number" || t === "boolean"
    }

    function indentForLog(level) {
        var out = ""
        for (var i = 0; i < level; i++)
            out += "    "
        return out
    }

    function stripOneIndentForLog(line, level) {
        var pad = indentForLog(level)
        if (line.indexOf(pad) === 0)
            return line.slice(pad.length)
        return line
    }

    function formatRegistryEntryInline(e, indentLevel) {
        var pad = indentForLog(indentLevel ?? 0);
        if (!e) return pad + "{}";

        return pad + "{"
                + "stableKey: " + String(e.stableKey)
                + ", musicXmlId: " + String(e.musicXmlId)
                + ", normalizedInstLongName: " + String(e.normalizedInstLongName)
                + ", staffOffsetWithinInst: " + Number(e.staffOffsetWithinInst)
                + ", staffIdx: " + Number(e.staffIdx)
                + "}";
    }

    function formatInlineForLog(value) {
        if (value === null)
            return "null"

        if (value === undefined)
            return "undefined"

        var t = typeof value

        if (t === "string" || t === "number" || t === "boolean")
            return String(value)

        if (Array.isArray(value)) {
            if (!value.length)
                return "[]"

            for (var a = 0; a < value.length; a++) {
                if (!isInlineScalarForLog(value[a]))
                    return null
            }

            var inlineItems = []
            for (var aa = 0; aa < value.length; aa++) {
                inlineItems.push(String(formatInlineForLog(value[aa])))
            }
            return "[" + inlineItems.join(",") + "]"
        }

        if (t === "object") {
            var keys = Object.keys(value)
            if (!keys.length)
                return "{}"

            var maxInlineObjectProps = 3
            if (keys.length > maxInlineObjectProps)
                return null

            var inlineParts = []
            for (var k = 0; k < keys.length; k++) {
                var key = keys[k]
                var childValue = value[key]
                if (!isInlineScalarForLog(childValue))
                    return null
                inlineParts.push(key + ": " + formatInlineForLog(childValue))
            }

            return "{" + inlineParts.join(", ") + "}"
        }

        return String(value)
    }

    function logMultilineDebug(prefix, text) {
        if (prefix)
            __logDebug(prefix);
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; ++i) {
            __logDebug(lines[i]);
        }
    }

    function formatForLog(value, indent) {
        indent = indent || 0

        var pad = indentForLog(indent)
        var childIndent = indent + 1
        var childPad = indentForLog(childIndent)

        var inline = formatInlineForLog(value)
        if (inline !== null)
            return pad + inline

        if (Array.isArray(value)) {
            var arrLines = [pad + "["]

            for (var a = 0; a < value.length; a++) {
                var formattedItem = formatForLog(value[a], childIndent)
                var itemLines = formattedItem.split("\n")

                for (var ai = 0; ai < itemLines.length; ai++) {
                    arrLines.push(itemLines[ai])
                }

                if (a < value.length - 1)
                    arrLines[arrLines.length - 1] += ","
            }

            arrLines.push(pad + "]")
            return arrLines.join("\n")
        }

        if (typeof value === "object") {
            var keys = Object.keys(value)
            var objLines = [pad + "{"]

            for (var k = 0; k < keys.length; k++) {
                var key = keys[k]
                var formattedVal = formatForLog(value[key], childIndent)
                var valLines = formattedVal.split("\n")

                if (valLines.length === 1) {
                    objLines.push(
                                childPad +
                                key +
                                ": " +
                                stripOneIndentForLog(valLines[0], childIndent) +
                                (k < keys.length - 1 ? "," : "")
                                )
                } else {
                    objLines.push(
                                childPad +
                                key +
                                ": " +
                                stripOneIndentForLog(valLines[0], childIndent)
                                )

                    for (var vi = 1; vi < valLines.length; vi++) {
                        objLines.push(valLines[vi])
                    }

                    if (k < keys.length - 1)
                        objLines[objLines.length - 1] += ","
                }
            }

            objLines.push(pad + "}")
            return objLines.join("\n")
        }

        return pad + String(value)
    }

    function logPrettyPresets(prefix, obj) {
        var pretty = formatForLog(obj, 0)
        var lines = pretty.split("\n")

        if (!lines.length) {
            __logDebug(prefix)
            return
        }

        __logDebug(prefix + " " + stripOneIndentForLog(lines[0], 0))

        for (var i = 1; i < lines.length; i++) {
            __logDebug(lines[i])
        }
    }

    // --- Clipboard + helpers ----------------------------------------------------
    // Holds a snapshot of a preset's assignments:
    // { noteRowsByStableKey: { [stableKey]: { instLongName, rows: [{active, offset, voice} x 8] } } }
    property var presetClipboard: null

    function __deepCloneRowsArray(rows) {
        var out = [];
        for (var i = 0; i < 8; ++i) {
            var r = (rows && rows[i]) ? rows[i] : { active: false, offset: 0, voice: 0 };
            out.push({
                         active: !!r.active,
                         offset: Number(r.offset || 0),
                         voice: Number(r.voice || 0)
                     });
        }
        return out;
    }

    function __stableKeysWithAnyActive(p) {
        return presetActiveStableKeys(p)
    }

    function __presetIsEmpty(p) {
        return __stableKeysWithAnyActive(p).length === 0;
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
        if (!p || !p.noteRowsByStableKey) return;
        var clip = {
            noteRowsByStableKey: {}
        };
        clip.name = String(p.name ?? "");
        clip.backgroundColor = "";
        if (p.backgroundColor) {
            clip.backgroundColor = (typeof p.backgroundColor === "string")
                    ? String(p.backgroundColor)
                    : colorToHex(p.backgroundColor);
        }
        var keys = __stableKeysWithAnyActive(p);
        for (var i = 0; i < keys.length; ++i) {
            var stableKey = keys[i];
            clip.noteRowsByStableKey[stableKey] = {
                instLongName: presetInstLongNameForStableKey(p, stableKey),
                rows: __deepCloneRowsArray(presetRowsForStableKey(p, stableKey))
            };
        }
        presetClipboard = clip
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

        if (!p.noteRowsByStableKey) p.noteRowsByStableKey = {};
        if (presetClipboard.noteRowsByStableKey) {
            for (var stableKey in presetClipboard.noteRowsByStableKey) {
                if (!presetClipboard.noteRowsByStableKey.hasOwnProperty(stableKey)) continue;
                var srcEntry = presetClipboard.noteRowsByStableKey[stableKey] || {};
                p.noteRowsByStableKey[stableKey] = {
                    instLongName: String(srcEntry.instLongName ?? ""),
                    rows: __deepCloneRowsArray(srcEntry.rows || [])
                };
            }
        }

        // Rename the target preset to "<source name> copy"
        var baseName = (presetClipboard && typeof presetClipboard.name === 'string' && presetClipboard.name.length)
                ? presetClipboard.name
                : qsTr("New Preset");
        p.name = baseName + qsTr(" copy");

        // Restore backgroundColor (if any)
        if (presetClipboard.backgroundColor && presetClipboard.backgroundColor.length) {
            p.backgroundColor = presetClipboard.backgroundColor; // hex → parsed automatically
        } else {
            try { delete p.backgroundColor; } catch(e) {}
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
        refreshStaffActiveRows();
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

    // Instrument name (no ": Staff N") on the preset card
    function staffInstrumentNameByIdx(staffIdx) {
        var p = partForStaff(staffIdx);
        var nm = nameForPart(p, 0) || qsTr("Unknown instrument");
        return cleanName(nm);
    }

    // Join instrument names for the preset card
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
                                 // Count UNIQUE active row indices (0..7) across ALL stableKey entries
                                 // that have data in noteRowsByStableKey
                                 var seen = {};
                                 if (p && p.noteRowsByStableKey) {
                                     for (var stableKey in p.noteRowsByStableKey) {
                                         if (!p.noteRowsByStableKey.hasOwnProperty(stableKey))
                                             continue;
                                         var rows = presetRowsForStableKey(p, stableKey);
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
                                 if (!p || !p.noteRowsByStableKey)
                                     return "";
                                 var keys = presetActiveStableKeys(p);
                                 return presetInstLongNamesFromStableKeys(p, keys);
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

    function refreshStaffActiveRows() {
        for (var i = 0; i < staffListModel.count; ++i) {
            var staffIdx = staffListModel.get(i).idx
            staffListModel.setProperty(
                        i,
                        "hasActiveRows",
                        staffHasActiveRowsInCurrentPreset(staffIdx)
                        )
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

        // Never modify assignments if no staff is currently focused
        var sid = -1;
        if (orchestratorWin && orchestratorWin.staffListRef && orchestratorWin.staffListRef.currentIndex >= 0)
            sid = staffListModel.get(orchestratorWin.staffListRef.currentIndex).idx;
        if (sid < 0)
            return;

        var stableKey = stableKeyForStaff(sid, 0);
        if (!stableKey.length)
            return;

        if (!p.noteRowsByStableKey)
            p.noteRowsByStableKey = {};

        var rows = [];
        for (var i = 0; i < 8; ++i) {
            var active = nb ? !!nb.selectedNotes[i] : false;
            var voice = Number(nb && nb.voiceByRow ? (nb.voiceByRow[i] ?? 0) : 0);
            var pitchIx = (nb && nb.pitchIndexByRow && nb.pitchIndexByRow[i] !== undefined) ? nb.pitchIndexByRow[i] : root.pitchCenterIndex;
            var offset = pitchIndexToValue(pitchIx);
            rows.push({ active: active, offset: offset, voice: voice });
        }

        if (hasAnyActiveRows(rows)) {
            p.noteRowsByStableKey[stableKey] = {
                instLongName: instLongNameForStaff(sid, 0),
                rows: rows
            };
        } else {
            try { delete p.noteRowsByStableKey[stableKey]; } catch (e) {}
        }
    }

    // Gather the 8 rows from the current Note Buttons UI (selected, voice, offset)
    function collectRowsFromNoteButtons() {
        var nb = orchestratorWin ? orchestratorWin.noteButtonsPaneRef : null;
        var rows = [];
        for (var i = 0; i < 8; ++i) {
            var active  = nb ? !!nb.selectedNotes[i] : false;
            var voice   = Number(nb && nb.voiceByRow ? (nb.voiceByRow[i] ?? 0) : 0);
            var pitchIx = (nb && nb.pitchIndexByRow && nb.pitchIndexByRow[i] !== undefined) ? nb.pitchIndexByRow[i] : root.pitchCenterIndex;
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

            // 2) Reset voices: default each row to voice 0
            var vb = {};
            for (var i = 0; i < 8; ++i) vb[i] = 0;
            nb.voiceByRow = vb;

            // 3) Reset pitch indices to center (36 == 0 semitones)
            var pi = {};
            for (var j = 0; j < 8; ++j) pi[j] = root.pitchCenterIndex;
            nb.pitchIndexByRow = pi;
        } finally {
            root.liveCommitEnabled = prevCommit;   // restore previous policy
        }
    }

    // Commit current UI rows to the current preset for all selected staves
    // (or the focused staff if none are selected). Then notify and refresh the cards.
    function commitNoteRowsToPresetLive() {
        if (root.creatingNewPreset || !root.liveCommitEnabled)
            return;

        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        if (!uiRef || uiRef.selectedIndex < 0 || uiRef.selectedIndex >= presets.length)
            return;

        var p = presets[uiRef.selectedIndex];
        if (!p) return;
        if (!p.noteRowsByStableKey) p.noteRowsByStableKey = {};

        // Targets: all selected staves; if none, use the focused staff
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
            if (sid >= 0) targetIds.push(sid);
            else return;
        }

        var rows = collectRowsFromNoteButtons();

        for (var t = 0; t < targetIds.length; ++t) {
            var sId = targetIds[t];
            var stableKey = stableKeyForStaff(sId, 0);
            if (!stableKey.length)
                continue;

            if (hasAnyActiveRows(rows)) {
                var cloned = [];
                for (var i = 0; i < rows.length; ++i)
                    cloned.push({ active: rows[i].active, offset: rows[i].offset, voice: rows[i].voice });

                p.noteRowsByStableKey[stableKey] = {
                    instLongName: instLongNameForStaff(sId, 0),
                    rows: cloned
                };
            } else {
                try { delete p.noteRowsByStableKey[stableKey]; } catch (e) {}
            }
        }

        notifyPresetsMutated();
        refreshStaffActiveRows();

        var keep = uiRef.selectedIndex;
        refreshPresetsListModel();
        refreshStaffActiveRows();
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

            if (sid < 0)
                return;

            var stableKey = stableKeyForStaff(sid, 0);
            var rowsForStaff = stableKey.length ? presetRowsForStableKey(p, stableKey) : [];
            if (!rowsForStaff || !rowsForStaff.length)
                rowsForStaff = defaultRows();

            var vb = {}, pi = {};
            for (var i = 0; i < 8; ++i) {
                var row = rowsForStaff[i] ?? { active:false, offset:0, voice:0 };
                if (row.active) nb.setNoteSelected(i, true)
                vb[i] = (row.voice >= 0 && row.voice <= 3) ? row.voice : 0
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
        refreshStaffActiveRows();

        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null;
        var tf   = orchestratorWin ? orchestratorWin.presetTitleFieldRef : null;
        if (uiRef) {
            var newSel = (presets.length > 0) ? Math.min(idx, presets.length - 1) : -1;

            // Update the title immediately (authoritative)
            if (tf) {
                if (newSel >= 0 && newSel < presets.length) {
                    tf.text = String(presets[newSel].name || qsTr("New Preset"));
                } else {
                    tf.text = qsTr("");
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
        refreshStaffActiveRows()
        savePresetsToSettings()

        var keep = uiRef ? uiRef.selectedIndex : -1
        refreshPresetsListModel()
        refreshStaffActiveRows();
        if (uiRef && model)
            uiRef.selectedIndex = Math.min(keep, Math.max(0, model.count - 1))
    }

    function commitPresetNameOnly() {
        var uiRef = orchestratorWin ? orchestratorWin.rootUIRef : null
        var tf = orchestratorWin ? orchestratorWin.presetTitleFieldRef : null
        if (!uiRef || !tf) return

        var sel = uiRef.selectedIndex
        if (sel < 0 || sel >= presets.length) return

        var p = presets[sel]
        if (!p) return

        var newName = String(tf.text ?? "")
        if (!newName.length) newName = qsTr("New Preset")

        // Update data model
        p.name = newName

        // Make bindings and cards refresh immediately
        notifyPresetsMutated()
        refreshPresetsListModel()
        refreshStaffActiveRows()

        // Persist
        savePresetsToSettings()
    }

    function stripHtmlTags(s) {
        return String(s || "").replace(/\<[^>]*\>/g, "")
    }

    function decodeHtmlEntities(s) {
        var t = String(s || "")
        t = t.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&#39;/g, "'")
        t = t.replace(/&#([0-9]+);/g, function(_, n) { return String.fromCharCode(parseInt(n, 10) || 0) })
        t = t.replace(/&#x([0-9a-fA-F]+);/g, function(_, h) { return String.fromCharCode(parseInt(h, 16) || 0) })
        return t
    }

    function cleanName(s) {
        return String(s || '').split('\r\n').join(' ').split('\n').join(' ')
    }

    function normalizeUiText(s) {
        return cleanName(decodeHtmlEntities(stripHtmlTags(s)))
    }

    function normalizeInstLongName(s) {
        var out = normalizeUiText(s)
        out = String(out ?? "").toLowerCase()
        out = out.replace(/♭/g, "b").replace(/♯/g, "sharp")
        out = out.replace(/[^a-z0-9]+/g, "")
        return out
    }

    function musicXmlIdForStaff(staffIdx, tick) {
        var inst = __instrumentAtTickForStaff(staffIdx, tick)
        var out = ""
        try { out = String((inst && inst.musicXmlId) ?? "") } catch (e0) {}
        if (out.length)
            return out

        var p = partForStaff(staffIdx)
        try { out = String((p && p.instrumentId) ?? "") } catch (e1) {}
        return out
    }

    function instLongNameForStaff(staffIdx, tick) {
        var inst = __instrumentAtTickForStaff(staffIdx, tick)
        var out = ""
        try { out = String((inst && inst.longName) ?? "") } catch (e0) {}
        out = normalizeUiText(out)
        if (out.length)
            return out
        return nameForPart(partForStaff(staffIdx), tick)
    }

    function staffOffsetWithinInst(staffIdx) {
        var sid = Number(staffIdx)
        if (isNaN(sid) || sid < 0)
            return -1
        var p = partForStaff(sid)
        if (!p)
            return -1
        var baseStaff = Math.floor(p.startTrack / 4)
        return sid - baseStaff
    }

    function stableKeyForStaff(staffIdx, tick) {
        var sid = Number(staffIdx)
        if (isNaN(sid) || sid < 0)
            return ""
        var mx = musicXmlIdForStaff(sid, tick)
        var nm = normalizeInstLongName(instLongNameForStaff(sid, tick))
        var off = staffOffsetWithinInst(sid)
        if (!mx.length || !nm.length || off < 0)
            return ""
        return mx + "|" + nm + "|" + off
    }

    function remapSelectedStaffByStableKey() {
        var newSelected = ({})
        for (var k in selectedStaff) {
            if (!selectedStaff.hasOwnProperty(k)) continue
            var oldStaffIdx = Number(k)
            var stableKey = stableKeyForStaff(oldStaffIdx, 0)
            if (!stableKey) continue

            var matches = activeScoreRegistryStaffIdxsForStableKey(stableKey)
            if (matches.length === 1) {
                newSelected[matches[0]] = true
            }
        }
        selectedStaff = newSelected
        bumpSelection()
    }

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
        var base = nameForPart(partForStaff(staffIdx), 0) || qsTr("Unknown instrument")
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
                    staffListModel.append({ idx: staffIdx, name: display, hasActiveRows: false })
                }
            }
        }

        rebuildActiveScoreRegistry(0)

        // Do not auto-select any staff on open
        var sl = orchestratorWin ? orchestratorWin.staffListRef : null
        if (sl) sl.currentIndex = -1
        clearSelection()
    }

    //--------------------------------------------------------------------------------
    // Orchestration Engine
    //
    // cmd() strings must match MuseScore command names
    // see src/notationscene/internal/notationuiactions.cpp
    //--------------------------------------------------------------------------------

    function __doCopy()                 { cmd("action://copy") }
    function __doPaste()                { cmd("action://paste") }

    // --- Command primitives: navigation / selection -----------------------------

    function __doMoveLeft()             { cmd("notation-move-left") }
    function __doMoveRight()            { cmd("notation-move-right") }
    function __doUpChord()              { cmd("up-chord") }
    function __doDownChord()            { cmd("down-chord") }
    function __doTopChord()             { cmd("top-chord") }
    function __doBottomChord()          { cmd("bottom-chord") }
    function __doEscape()               { cmd("action://cancel") }

    function __clearScoreSelection() {
        try {
            if (curScore && curScore.selection && typeof curScore.selection.clear === "function")
                curScore.selection.clear();
        } catch (e) {}
    }

    // --- Command primitives: mutation -------------------------------------------

    function __doDelete()               { cmd("action://delete") }
    function __doPitchUp()              { cmd("pitch-up") }
    function __doPitchDown()            { cmd("pitch-down") }
    function __doPitchUpOctave()        { cmd("pitch-up-octave") }
    function __doPitchDownOctave()      { cmd("pitch-down-octave") }
    function __doPitchUpDiatonic()      { cmd("pitch-up-diatonic") }
    function __doPitchDownDiatonic()    { cmd("pitch-down-diatonic") }
    function __doFlip()                 { cmd("flip") }

    function __applyPitchOffsetCommands(offset) {
        var steps = Number(offset || 0)
        while (steps >= 12) {
            __doPitchUpOctave()
            steps -= 12
        }
        while (steps <= -12) {
            __doPitchDownOctave()
            steps += 12
        }
        while (steps > 0) {
            __doPitchUp()
            steps -= 1
        }
        while (steps < 0) {
            __doPitchDown()
            steps += 1
        }
    }

    function __doSetVoice1()            { cmd("voice-1") } // preferred - keeps dynamics with voice and doesn't select other voices
    function __doSetVoice2()            { cmd("voice-2") }
    function __doSetVoice3()            { cmd("voice-3") }
    function __doSetVoice4()            { cmd("voice-4") }

    function __setVoice(v) {
        // API index: 0..3 (#track % 4)
        var vv = Number(v ?? 0)
        if (vv < 0) vv = 0
        if (vv > 3) vv = 3
        // convert API index to UI index 0..3 => 1..4
        cmd("voice-" + (vv + 1))
    }

    // --- Row labeling & diagnostics (UI / warnings only) ------------------------
    function __rowLabel(rowIndex) {
        if (rowIndex === 0) return "T" // Top
        if (rowIndex === 6) return "S" // Second
        if (rowIndex === 7) return "B" // Bottom
        return String(rowIndex)
    }

    function __recordIgnoredRows(warningSink, staffIdx, tick, noteCount, rowIndices) {
        if (!warningSink || !rowIndices || !rowIndices.length)
            return
        var sig = staffIdx + ":" + tick + ":" + noteCount + ":" + rowIndicies.join(",")

        if (!warningSink._seen)
            warningSink._seen = {}

        if (warningSink._seen[sig])
            return

        warningSink._seen[sig] = true
        warningSink.push({
                             staffIdx,
                             tick,
                             noteCount,
                             rows: rowIndicies.slice(0)
                         })
    }

    function __showIgnoredRowWarnings(warnings) {
        if (!warnings || !warnings.length)
            return

        var grouped = ({})
        for (var i = 0; i < warnings.length; ++i) {
            var w = warnings[i]
            var key = String(w.staffIdx) + "|" + String(w.noteCount)

            if (!grouped[key]) {
                grouped[key] = {
                    staffIdx: w.staffIdx,
                    noteCount: w.noteCount,
                    rows: ({})
                }
            }

            for (var r = 0; r < w.rows.length; ++r) {
                grouped[key].rows[String(w.rows[r])] = true
            }
        }

        var lines = []
        for (var key in grouped) {
            if (!grouped.hasOwnProperty(key))
                continue

            var g = grouped[key]
            var rowNums = []

            for (var rk in g.rows) {
                if (g.rows.hasOwnProperty(rk))
                    rowNums.push(Number(rk))
            }

            rowNums.sort(function(a, b) { return a - b })

            var names = []
            for (var j = 0; j < rowNums.length; ++j) {
                var rowIndex = rowNums[j]
                if (rowIndex === 0) names.push("Top / Single note")
                else if (rowIndex === 6) names.push("Second note")
                else if (rowIndex === 7) names.push("Bottom note")
                else names.push(__rowLabel(rowIndex))
            }

            lines.push(
                        staffInstrumentNameByIdx(g.staffIdx) +
                        ": ignored " +
                        names.join(", ") +
                        " on " + g.noteCount + "-note chords."
                        )
        }

        if (!lines.length)
            return

        Interactive.info(
                    qsTr("Some preset rows were ignored."),
                    lines.join("\n"),
                    [qsTr("Ok")]
                    )
    }

    // --- Selection & Cursor helpers (planning / anchoring only) -----------------

    function staffBaseTrack(staffIdx) {
        return staffIdx * 4
    }

    function __selectionSingleVoiceIndexOrNull() {
        if (!curScore || !curScore.selection) return -1
        var els = null
        try { els = curScore.selection.elements } catch (e0) { els = null }
        if (!els || !els.length) return -1

        var found = null
        function considerTrack(tr) {
            var t = Number(tr)
            if (isNaN(t)) return true
            var v = t % 4
            if (found === null) { found = v; return true }
            return (v === found)
        }

        for (var i = 0; i < els.length; ++i) {
            var el = els[i]
            // If element itself has a track (common for notes)
            try {
                if (el && el.track !== undefined && el.track !== null) {
                    if (!considerTrack(el.track)) return null // multiple voices
                }
            } catch (e1) {}

            // If it's a chord-like element, check its notes too
            try {
                if (el && el.notes && el.notes.length) {
                    for (var n = 0; n < el.notes.length; ++n) {
                        var nt = el.notes[n]
                        if (nt && nt.track !== undefined && nt.track !== null) {
                            if (!considerTrack(nt.track)) return null // multiple voices
                        }
                    }
                }
            } catch (e2) {}
        }

        // NEW: if we never encountered any track-bearing items, it's "no notes selected"
        if (found === null) return -1

        return found
    }

    function __selectionSingleStaffIndexOrNull() {
        if (!curScore || !curScore.selection)
            return -1

        var els = null
        try { els = curScore.selection.elements } catch (e0) { els = null }
        if (!els || !els.length)
            return -1

        var found = null

        function considerTrack(tr) {
            var t = Number(tr)
            if (isNaN(t))
                return true
            var s = Math.floor(t / 4)
            if (found === null) {
                found = s
                return true
            }
            return (s === found)
        }

        for (var i = 0; i < els.length; ++i) {
            var el = els[i]

            try {
                if (el && el.track !== undefined && el.track !== null) {
                    if (!considerTrack(el.track))
                        return null
                }
            } catch (e1) {}

            try {
                if (el && el.notes && el.notes.length) {
                    for (var n = 0; n < el.notes.length; ++n) {
                        var nt = el.notes[n]
                        if (nt && nt.track !== undefined && nt.track !== null) {
                            if (!considerTrack(nt.track))
                                return null
                        }
                    }
                }
            } catch (e2) {}
        }

        if (found === null)
            return -1

        return found
    }

    function __getSourceSelectionSegments() {
        if (!curScore) return { start: null, end: null }

        var c = curScore.newCursor()
        if (!c) return { start: null, end: null }

        var startSeg = null
        var endSeg = null

        try { c.rewind(Cursor.SELECTION_START) } catch (e) { try { c.rewind(1) } catch (e2) {} }
        startSeg = c.segment

        try { c.rewind(Cursor.SELECTION_END) } catch (e) { try { c.rewind(2) } catch (e2) {} }
        endSeg = c.segment

        if (!startSeg) return { start: null, end: null }
        if (!endSeg) endSeg = startSeg

        var st = (startSeg.tick !== undefined) ? startSeg.tick : 0
        var et = (endSeg.tick !== undefined) ? endSeg.tick : st

        if (et <= st) {
            try { c.rewind(Cursor.SELECTION_START) } catch (e) { try { c.rewind(1) } catch (e2) {} }
            c.next()
            if (c.segment) endSeg = c.segment
        }

        return { start: startSeg, end: endSeg }
    }

    function __seekCursorToTick(c, targetTick) {
        if (!c) return false

        var t = Number(targetTick ?? 0)

        // Establish a defined cursor location on a known-good track (0),
        // then restore the desired track. Some builds can fail rewind() on voice>0 tracks.
        var desiredTrack = 0
        try { desiredTrack = Number(c.track ?? 0) } catch (e0) { desiredTrack = 0 }

        try { c.track = 0 } catch (e1) {}
        try { c.rewind(Cursor.SCORE_START) } catch (e) { try { c.rewind(0) } catch (e2) {} }

        try { c.track = desiredTrack } catch (e3) {}

        // If switching back invalidated the segment, rewind again now that track is set.
        if (!c.segment) {
            try { c.rewind(Cursor.SCORE_START) } catch (e4) { try { c.rewind(0) } catch (e5) {} }
        }

        var guard = 0
        while (c.segment && c.segment.tick !== undefined && c.segment.tick < t && guard < 200000) {
            c.next()
            guard++
        }

        return !!c.segment
    }

    function __selectAnchorForStaffAtTick(staffIdx, tick) {
        if (!curScore)
            return false

        var c = curScore.newCursor()
        if (!c)
            return false

        c.track = staffBaseTrack(staffIdx)

        if (!__seekCursorToTick(c, Number(tick || 0)))
            return false

        var el = c.element
        if (!el)
            return false

        try {
            if (el.type === Element.CHORD && el.notes && el.notes.length)
                curScore.selection.select(el.notes[0])
            else
                curScore.selection.select(el)
            return true
        } catch (e) {
            return false
        }
    }

    function __selectChordNoteAtTick(staffIdx, voiceIdx, tick) {
        if (!curScore || tick === undefined || tick === null)
            return false

        var c = curScore.newCursor()
        if (!c)
            return false

        c.track = staffBaseTrack(staffIdx) + voiceIdx
        if (!__seekCursorToTick(c, tick))
            return false

        var el = c.element
        if (!el || !el.notes || !el.notes.length)
            return false

        try {
            curScore.selection.select(el.notes[0])
            return true
        } catch (e) {
            return false
        }
    }

    function __snapshotSourceSelectionForRestore() {
        if (!curScore ||
                !curScore.selection)
            return null

        var sourceStaffIdx = __selectionSingleStaffIndexOrNull()
        var sourceVoiceIdx = __selectionSingleVoiceIndexOrNull()
        if (sourceStaffIdx === null || sourceVoiceIdx === null)
            return null
        if (sourceStaffIdx < 0 || sourceVoiceIdx < 0)
            return null

        var segs = __getSourceSelectionSegments()
        if (!segs.start)
            return null

        var startTick = (segs.start.tick !== undefined) ? Number(segs.start.tick) : 0
        var endTickExclusive = (segs.end && segs.end.tick !== undefined) ? Number(segs.end.tick) : startTick

        if (endTickExclusive <= startTick)
            return null

        return {
            startTick: startTick,
            endTick: endTickExclusive,
            startStaff: sourceStaffIdx,
            endStaff: sourceStaffIdx + 1
        }
    }

    function __restoreSelection(snapshot) {
        if (!snapshot ||
                !curScore ||
                !curScore.selection)
            return false

        Qt.callLater(function () {
            if (!snapshot ||
                    !curScore ||
                    !curScore.selection)
                return

            var startedSelCmd = false
            var ok = false

            try { __clearScoreSelection() } catch (e0) {}

            try {
                if (curScore.startCmd) {
                    curScore.startCmd()
                    startedSelCmd = true
                }
            } catch (e1) {}

            try {
                ok = !!curScore.selection.selectRange(
                            Number(snapshot.startTick),
                            Number(snapshot.endTick),
                            Number(snapshot.startStaff),
                            Number(snapshot.endStaff)
                            )
            } catch (e2) {
                ok = false
            }

            if (startedSelCmd) {
                try { curScore.endCmd() } catch (e3) {}
            }

            if (!ok) {
                __logWarn("firePreset: delayed selection restore failed")
            }
        })

        return true
    }

    // --- Overwrite modal helpers ------------------------------------------------

    function __trackHasNotesInTickRange(track, startTick, endTick) {
        // Treat "has notes" as: any CHORD element with at least 1 note.
        // __collectChordsInTickRangeForTrack() already filters to chords-with-notes.
        var chords = __collectChordsInTickRangeForTrack(track, startTick, endTick);
        return !!(chords && chords.length);
    }

    function __staffHasNotesInTickRange(staffIdx, startTick, endTick) {
        // Check all 4 voice tracks for this staff.
        var base = staffBaseTrack(staffIdx);
        for (var v = 0; v < 4; ++v) {
            if (__trackHasNotesInTickRange(base + v, startTick, endTick))
                return true;
        }
        return false;
    }

    function __detectOverwriteStaffIds(staffIds, startTick, endTick) {
        // Returns subset of staffIds that contain any notes in the range.
        var out = [];
        if (!staffIds || !staffIds.length) return out;
        for (var i = 0; i < staffIds.length; ++i) {
            var sid = Number(staffIds[i]);
            if (sid < 0 || isNaN(sid)) continue;
            if (__staffHasNotesInTickRange(sid, startTick, endTick))
                out.push(sid);
        }
        return out;
    }

    // --- Source analysis & planning (read-only - should never issue cmd()) ------

    function __collectChordsInTickRangeForTrack(track, startTick, endTick) {
        var out = [];
        if (!curScore) return out;

        var st = Number(startTick ?? 0);
        var et = Number(endTick ?? st);
        if (et < st) { var tmp = st; st = et; et = tmp; }

        var c = curScore.newCursor();
        if (!c) return out;

        c.track = Number(track ?? 0);

        if (!__seekCursorToTick(c, st)) return out;

        var guard = 0;
        while (c.segment && c.segment.tick !== undefined && c.segment.tick < et && guard < 200000) {
            var el = c.element;
            if (el && el.notes && el.notes.length) {
                // IMPORTANT: capture the tick from the cursor (reliable),
                // because chord.segment.tick is logging as "?" in runtime.
                out.push({ chord: el, tick: c.tick });
            }
            c.next();
            guard++;
        }

        return out;
    }

    function __sortedNotesHighToLow(notes) {
        var out = []
        for (var i = 0; i < notes.length; ++i)
            out.push(notes[i])

        out.sort(function(a, b) {
            var pa = (a && a.pitch !== undefined) ? Number(a.pitch) : 0
            var pb = (b && b.pitch !== undefined) ? Number(b.pitch) : 0
            return pb - pa
        })

        return out
    }

    function __orderedValidRowsForNoteCount(noteCount) {
        var n = Number(noteCount || 0)
        if (n <= 0) return []
        if (n === 1) return [0]

        var out = [0]
        var start = 8 - (n - 1)
        if (start < 1) start = 1
        for (var r = start; r <= 7; ++r)
            out.push(r)
        return out
    }

    function __mapRowToNoteIndex(rowIndex, noteCount) {
        if (noteCount <= 1) return 0

        // rowIndex: 0..7 (Top..Bottom labels)
        // fromBottom: Bottom row (7) => 0, Second row (6) => 1, ..., Top row (0) => 7
        var fromBottom = 7 - rowIndex

        // notes are sorted high→low, so bottom is index (noteCount - 1)
        var ix = (noteCount - 1) - fromBottom

        // clamp into valid chord note indices
        if (ix < 0) ix = 0
        if (ix > noteCount - 1) ix = noteCount - 1
        return ix
    }

    function __voicesUsedByRows(rows) {
        var seen = {};
        var out = [];
        if (!rows || !rows.length) return out;

        for (var i = 0; i < 8; ++i) {
            var r = rows[i];
            if (!r || !r.active) continue;
            var v = Number(r.voice ?? 0);
            if (v < 0) v = 0;
            if (v > 3) v = 3;
            if (!seen[v]) {
                seen[v] = true;
                out.push(v);
            }
        }
        out.sort(function(a,b){ return a-b; });
        return out;
    }

    function __buildSourceChordPlan(sourceStaffIdx, startTick, endTick, rows, warningSink) {
        var plan = []
        var sourceTrack = staffBaseTrack(sourceStaffIdx)
        var sourceChords = __collectChordsInTickRangeForTrack(sourceTrack, startTick, endTick)
        for (var i = 0; i < sourceChords.length; ++i) {
            var chordObj = sourceChords[i]
            var chord = (chordObj && chordObj.chord) ? chordObj.chord : chordObj
            var tick = (chordObj && chordObj.tick !== undefined) ? Number(chordObj.tick) : 0

            if (!chord || !chord.notes || !chord.notes.length)
                continue

            var noteCount = chord.notes.length
            var orderedRows = __orderedValidRowsForNoteCount(noteCount)

            if (!orderedRows.length)
                continue

            var validSet = ({})
            for (var vr = 0; vr < orderedRows.length; ++vr)
                validSet[String(orderedRows[vr])] = true

            var notes = __sortedNotesHighToLow(chord.notes)
            var rowsByVoice = [({}), ({}), ({}), ({})]

            for (var r = 0; r < 8; ++r) {
                var rowObj = (rows && rows[r]) ? rows[r] : null
                if (!rowObj || !rowObj.active)
                    continue

                var voiceIdx = Number(rowObj.voice ?? 0)
                if (voiceIdx < 0) voiceIdx = 0
                if (voiceIdx > 3) voiceIdx = 3

                if (!validSet[String(r)]) {
                    __recordIgnoredRows(warningSink, sourceStaffIdx, tick, noteCount, [r])
                    continue
                }

                var noteIndex = __mapRowToNoteIndex(r, noteCount)
                var srcNote = notes[noteIndex]

                rowsByVoice[voiceIdx][String(r)] = {
                    rowIndex: r,
                    offset: Number(rowObj.offset ?? 0),
                    skipPitch: false
                }
            }

            plan.push({
                          tick: tick,
                          noteCount: noteCount,
                          rowsByVoice: rowsByVoice
                      })
        }

        return plan

    }

    function __passPlanForVoice(sourcePlan, voiceIdx) {
        var out = []

        for (var i = 0; i < sourcePlan.length; ++i) {
            var entry = sourcePlan[i]
            var rowsForVoice = entry.rowsByVoice[voiceIdx] || ({})
            var hasRows = false

            for (var k in rowsForVoice) {
                if (rowsForVoice.hasOwnProperty(k)) {
                    hasRows = true
                    break
                }
            }

            if (hasRows) {
                out.push({
                             tick: entry.tick,
                             noteCount: entry.noteCount,
                             rowsForVoice: rowsForVoice
                         })
            }
        }

        return out
    }



    function __runVoicePassFromSourcePlan(staffIdx, startTick, endTick, passPlan, voiceIdx) {
        if (!passPlan || !passPlan.length)
            return true

        // 1) Anchor at start tick on base voice (voice 1 / track 0)
        if (!__selectAnchorForStaffAtTick(staffIdx, startTick))
            return false

        // 2) Paste once (paste range becomes selected)
        __doPaste()

        // 3) Change voice while paste range is still selected
        if (voiceIdx !== 0)
            __setVoice(voiceIdx)

        // 4) Walk left to collapse range selection to first chord/note
        var stepsLeft = passPlan.length - 1
        for (var k = 0; k < stepsLeft; ++k)
            __doMoveLeft()

        // 5) Process each chord independently
        for (var i = 0; i < passPlan.length; ++i) {
            var entry = passPlan[i]
            if (!entry || entry.tick === undefined)
                continue

            __selectChordNoteAtTick(staffIdx, voiceIdx, entry.tick)

            var rowsForVoice = entry.rowsForVoice || ({})
            var orderedRows = __orderedValidRowsForNoteCount(entry.noteCount)

            // Normalize to top note of chord
            __doTopChord()

            var keptCount = 0
            for (var r = 0; r < orderedRows.length; ++r) {
                var rowIndex = orderedRows[r]
                var spec = rowsForVoice[String(rowIndex)]

                // Step down inside the chord only when needed
                if (keptCount > 0)
                    __doDownChord()

                if (!spec) {

                    // Row not used for this voice — BUT never delete tied notes
                    var els = curScore.selection.elements
                    var note = (els && els.length) ? els[0] : null

                    if (note && (note.tieBack || note.tieForward)) {
                        // Preserve tie chain integrity
                        keptCount += 1
                        continue
                    }

                    __doDelete()
                    continue
                }

                // Pitch ONLY on tie starts
                var els = curScore.selection.elements
                var note = (els && els.length) ? els[0] : null

                if (note && note.tieBack) {
                    // This is a tie continuation — do NOT pitch it
                    keptCount += 1
                    continue
                }

                if (!spec.skipPitch)
                    __applyPitchOffsetCommands(spec.offset)

                keptCount += 1
            }

            // Advance to next chord/rest
            __doMoveRight()
        }

        return true
    }

    function __doUndoBestEffort() {
        var candidates = [
                    "action://undo",
                    "action://notation/undo"
                ];
        for (var i = 0; i < candidates.length; ++i) {
            try {
                cmd(candidates[i]);
                return true;
            } catch (e) {}
        }
        return false;
    }

    function __resolvedAssignmentsForPresetInActiveScore(presetObj) {
        var resolvedAssignments = []
        var duplicateStableKeys = []
        var missingStableKeys = []

        if (!presetObj || !presetObj.noteRowsByStableKey) {
            return {
                resolvedAssignments: []
            }
        }

        // Collect active stableKeys from the preset
        var stableKeys = presetActiveStableKeys(presetObj)
        if (!stableKeys || !stableKeys.length) {
            return {
                resolvedAssignments: []
            }
        }

        // Ensure registry exists and is current
        if (!activeScoreRegistry || !activeScoreRegistry.byStableKey) {
            return {
                resolvedAssignments: []
            }
        }

        // Resolve each stableKey against the active score
        for (var i = 0; i < stableKeys.length; ++i) {
            var stableKey = stableKeys[i];
            var res = resolveStableKeyInActiveScore(stableKey)

            // Case 1: duplicate instruments (1 stableKey → many staves)
            if (res.status === "DUPLICATE") {
                duplicateStableKeys.push({
                                             stableKey: stableKey,
                                             instName: presetInstLongNameForStableKey(presetObj, stableKey),
                                             staffIdxs: res.candidateStaffIdxs.slice(0)
                                         })
                continue
            }

            // Case 2: missing instrument (preset refers to something not in score)
            if (res.status === "MISSING") {
                missingStableKeys.push({
                                           stableKey: stableKey,
                                           instName: presetInstLongNameForStableKey(presetObj, stableKey)
                                       })
                continue
            }

            // Case 3: exactly one match → valid assignment
            if (res.status === "RESOLVED") {
                resolvedAssignments.push({
                                             status: res.status,
                                             stableKey: res.stableKey,
                                             staffIdx: res.staffIdx,
                                             rows: presetRowsForStableKey(presetObj, stableKey)
                                         })
            }
        }

        // Hard stop: duplicate instruments must be resolved by the user
        if (duplicateStableKeys.length > 0) {
            return {
                duplicateStableKeys: duplicateStableKeys
            }
        }

        // Normal successful resolution
        return {
            resolvedAssignments: resolvedAssignments,
            missingStableKeys: missingStableKeys
        }
    }

    function __resolvedAssignmentStaffIds(assignments) {
        var out = [];
        if (!assignments || !assignments.length)
            return out;
        for (var i = 0; i < assignments.length; ++i) {
            var sid = Number(assignments[i].staffIdx);
            if (!isNaN(sid) && sid >= 0)
                out.push(sid);
        }
        return out;
    }

    function __showUnresolvedPresetTargetWarnings(presetObj, targetInfo) {
        if (!targetInfo)
            return;

        var lines = [];
        if (targetInfo.missingStableKeys && targetInfo.missingStableKeys.length) {
            for (var i = 0; i < targetInfo.missingStableKeys.length; ++i) {
                var missingKey = targetInfo.missingStableKeys[i];
                var missingName = presetInstLongNameForStableKey(presetObj, missingKey) || qsTr("Unknown instrument");
                lines.push(qsTr("Missing destination: %1").arg(missingName));
            }
        }
        if (targetInfo.duplicateStableKeys && targetInfo.duplicateStableKeys.length) {
            for (var j = 0; j < targetInfo.duplicateStableKeys.length; ++j) {
                var dupKey = targetInfo.duplicateStableKeys[j];
                var dupName = presetInstLongNameForStableKey(presetObj, dupKey) || qsTr("Unknown instrument");
                lines.push(qsTr("Duplicate destination: %1").arg(dupName));
            }
        }

        if (!lines.length)
            return;

        Interactive.info(
                    qsTr("Some preset destinations were skipped."),
                    lines.join("\n"),
                    [qsTr("Ok")]
                    );
    }

    function firePreset(presetIndex, opts) {
        opts = opts || {}
        if (!curScore) {
            __logError("firePreset: no curScore")
            return
        }
        if (presetIndex < 0 || presetIndex >= presets.length) {
            __logError("firePreset: invalid preset index " + presetIndex)
            return
        }
        var p = presets[presetIndex]
        if (!p || !p.noteRowsByStableKey) {
            __logWarn("firePreset: preset has no noteRowsByStableKey")
            return
        }

        var segs = __getSourceSelectionSegments()
        var startSeg = segs.start
        var endSeg = segs.end

        if (!startSeg) {
            __logWarn("firePreset: no score selection")
            Interactive.info(
                        qsTr("Nothing selected in the score."),
                        qsTr("Tip: Use the Selection filter to customize a selection."),
                        [qsTr("Ok")]
                        )
            return
        }

        var sourceStaffIdx = __selectionSingleStaffIndexOrNull()
        if (sourceStaffIdx === null) {
            __logWarn("firePreset: source selection spans multiple staves.")
            Interactive.info(
                        qsTr("Selection must be on one staff."),
                        qsTr("Combine the source material onto one staff and try again."),
                        [qsTr("Ok")]
                        )
            return
        }

        var selVoice = __selectionSingleVoiceIndexOrNull()
        if (selVoice === -1) {
            __logWarn("firePreset: No notes selected (no track-bearing items in selection).")
            Interactive.info(
                        qsTr("No notes selected."),
                        qsTr("Select at least one note or chord and try again."),
                        [qsTr("Ok")]
                        )
            return
        }

        if (selVoice === null) {
            __logWarn("firePreset: multiple source voices detected.")
            Interactive.info(
                        qsTr("Multiple voices detected."),
                        qsTr("Move the selection to Voice 1 and try again."),
                        [qsTr("Ok")]
                        )
            return
        }

        if (selVoice !== 0) {
            __logWarn("firePreset: source selection must be Voice 1 (API voice 0). selVoice=" + selVoice)
            Interactive.info(
                        qsTr("Selection must be Voice 1."),
                        qsTr("Move the selection to Voice 1 and try again."),
                        [qsTr("Ok")]
                        )
            return
        }

        var startTick = (startSeg.tick !== undefined) ? startSeg.tick : 0
        var endTick = (endSeg && endSeg.tick !== undefined) ? endSeg.tick : startTick

        rebuildActiveScoreRegistry(startTick)

        var targetInfo = __resolvedAssignmentsForPresetInActiveScore(p)

        if (targetInfo.duplicateStableKeys) {
            showDuplicateStableKeyModal(targetInfo.duplicateStableKeys)
            return
        }

        var resolvedAssignments = targetInfo.resolvedAssignments || []
        var targetStaffIds = __resolvedAssignmentStaffIds(resolvedAssignments)

        if (!targetStaffIds.length) {
            __logWarn("firePreset: no resolved destination staves in active score")
            Interactive.info(
                        qsTr("No preset destinations matched the active score."),
                        qsTr("Check instrument names/order in the score and try again."),
                        [qsTr("Ok")]
                        )
            return
        }

        var selectionSnapshot = __snapshotSourceSelectionForRestore()
        var skipOverwritePrompt = !!opts.skipOverwritePrompt
        if (!skipOverwritePrompt) {
            var overwriteStaffIds = __detectOverwriteStaffIds(targetStaffIds, startTick, endTick)
            if (overwriteStaffIds.length) {
                var names = staffInstrumentNamesFromIndices(overwriteStaffIds)
                root.pendingOverwrite = { presetIndex: presetIndex }
                let overwriteBtn = Interactive.question(
                        qsTr("Overwrite notes in destination staves?"),
                        qsTr("There are existing notes in %1.").arg(names),
                        ["Yes", "No"]
                        )
                if (!overwriteBtn || overwriteBtn === "No")
                    return
            }
        }

        __logInfo(
                    "firePreset startTick=" + startTick +
                    " endTick=" + endTick +
                    " targetStaffIds=" + JSON.stringify(targetStaffIds)
                    )

        var warnings = []
        var started = false
        var committed = false

        try {
            curScore.startCmd()
            started = true

            __doCopy()
            for (var t = 0; t < resolvedAssignments.length; ++t) {
                var assignment = resolvedAssignments[t]
                var staffIdx = Number(assignment.staffIdx)
                var rows = assignment.rows || []
                if (!rows || !hasAnyActiveRows(rows))
                    continue

                var warningBase = warnings.length
                var sourcePlan = __buildSourceChordPlan(sourceStaffIdx, startTick, endTick, rows, warnings)

                // Re-tag newly-added warnings so they point to the destination instrument,
                // not the source staff that was analyzed.
                for (var w = warningBase; w < warnings.length; ++w) {
                    warnings[w].staffIdx = staffIdx
                }

                if (!sourcePlan.length)
                    continue

                var voices = __voicesUsedByRows(rows)
                if (!voices.length)
                    continue

                // Highest voice first: 4 -> 3 -> 2 -> 1
                voices.sort(function(a, b) { return b - a })
                __logInfo(
                            "staffPass staffIdx=" + staffIdx +
                            " track=" + staffBaseTrack(staffIdx) +
                            " startTick=" + startTick +
                            " endTick=" + endTick +
                            " voices=" + JSON.stringify(voices)
                            )

                for (var vI = 0; vI < voices.length; ++vI) {
                    var voiceIdx = voices[vI]
                    var passPlan = __passPlanForVoice(sourcePlan, voiceIdx)
                    if (!passPlan.length) {
                        __logInfo(
                                    "voicePass skipped staffIdx=" + staffIdx +
                                    " voice=" + voiceIdx +
                                    " reason=no valid rows in source material"
                                    )
                        continue
                    }

                    __logDebug(
                                "voicePass staffIdx=" + staffIdx +
                                " voice=" + voiceIdx +
                                " tickCount=" + passPlan.length
                                )

                    var okPass = __runVoicePassFromSourcePlan(
                                staffIdx,
                                startTick,
                                endTick,
                                passPlan,
                                voiceIdx
                                )
                    if (!okPass) {
                        throw new Error(
                                    "Voice pass failed staffIdx=" + staffIdx +
                                    " voice=" + voiceIdx
                                    )
                    }
                }
            }

            curScore.endCmd()
            committed = true
            __showIgnoredRowWarnings(warnings)
            __showUnresolvedPresetTargetWarnings(p, targetInfo)

            if (!__restoreSelection(selectionSnapshot)) {
                __logWarn("firePreset: could not schedule original selection restore after success")
            }
        } catch (e) {
            __logError("firePreset exception: " + String(e))

            if (started && !committed) {
                try {
                    curScore.endCmd()
                } catch (eEnd) {}

                __doUndoBestEffort()
            }

            Interactive.info(
                        qsTr("Preset application failed."),
                        qsTr("The operation was rolled back. Check the log for details."),
                        [qsTr("Ok")]
                        )
            if (!__restoreSelection(selectionSnapshot)) {
                __logWarn("firePreset: could not schedule original selection restore after rollback")
            }
        }
    }

    ListModel { id: staffListModel }

    // --- Staff list selection helpers (UI-only, no score interaction) -----------

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
        for (var r = 0; r < staffListModel.count; ++r) {
            if (isStaffRowVisible(r))
                setRowSelected(r, true)
        }
        var sl = orchestratorWin ? orchestratorWin.staffListRef : null
        if (sl && sl.currentIndex < 0)
            sl.currentIndex = firstVisibleStaffRowIndex()
    }

    // Ensure the list is populated and the window is visible when the plugin opens
    onRun: {
        __logInfo("Hello Orchestrator")

        if (!orchestratorWin) {
            orchestratorWin = orchestratorWinComponent.createObject(root)
            __logInfo("Window created: " + orchestratorWin)
        }

        // Restore UI state (pre-show, no flicker)
        try {
            // Restore Settings panel state FIRST (drives width policy)
            root.settingsOpen = !!ocPrefs.lastSettingsOpen;

            // Width locked to either base or expanded; mirror toggle math
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

            // Restore gridView before populating cards (affects layout widths)
            root.gridView = !!ocPrefs.lastGridView;

            // Restore position pre-show (best-effort; clamped again post-show)
            try {
                var savedX = Number(ocPrefs.lastWindowX);
                var savedY = Number(ocPrefs.lastWindowY);
                var haveSavedPos = !(isNaN(savedX) || isNaN(savedY)) && (savedX !== 0 || savedY !== 0);

                if (haveSavedPos) {
                    orchestratorWin.x = savedX;
                    orchestratorWin.y = savedY;
                    orchestratorWin._centeredOnce = true; // Hard-disable any centering this session
                }
            } catch (e) {}
        } catch (e) {
            __logError("Restore UI state failed: " + String(e));
        }

        // Explicitly show/raise/activate the window and set its visibility state
        orchestratorWin.visibility = Window.Windowed
        orchestratorWin.show()
        orchestratorWin.raise()
        orchestratorWin.requestActivate()

        Qt.callLater(function () {
            // Restore window position (ensure on-screen)
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
                __logError("Restore window position failed: " + String(e));
            }

            __logDebug("Post-show visible: " + orchestratorWin.visible + " visibility: " + orchestratorWin.visibility)
            buildStaffListModel()
            refreshStaffActiveRows()
            refreshPresetsListModel()

            // Load presets (Settings-backed) and apply the first preset to the UI
            loadPresetsFromSettings()

            // Restore selected card (only when Settings panel is open)
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
                    uiRef.selectedIndex = -1; // Normal mode: no persistent selection
                }
            } catch (e) {
                __logError("Restore selected card failed: " + String(e));
            }
        })
    }

    //--------------------------------------------------------------------------------
    // UI
    //--------------------------------------------------------------------------------

    Component {
        id: orchestratorWinComponent
        Window {
            id: win
            // Treat as a normal, non-modal, top-level window
            visibility: Window.Windowed
            modality: Qt.NonModal
            title: root.title

            // Expose inner objects to root (so root-level helpers can reach them)
            property alias rootUIRef: rootUI
            property alias allPresetsModelRef: allPresetsModel
            property alias staffListRef: staffList
            property alias presetTitleFieldRef: presetTitleField
            property alias noteButtonsPaneRef: noteButtonsPane

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
            width:          baseWidth
            minimumWidth:   baseWidth
            maximumWidth:   baseWidth
            minimumHeight:  380

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

                // --- Preset list filtering ---
                property string setFilterText: ""
                // Single-selection: -1 = none, otherwise model index in allPresetsModel
                property int selectedIndex: -1
                // Backing model of all presets (settings-backed)
                ListModel {
                    id: allPresetsModel
                }

                onSelectedIndexChanged: {
                    if (!root.suppressApplyPreset &&
                            !root.creatingNewPreset &&
                            selectedIndex >= 0 &&
                            selectedIndex < allPresetsModel.count)
                    {
                        applyPresetToUI(selectedIndex);
                    }

                    if (root.settingsOpen && selectedIndex >= 0 && selectedIndex < presets.length) {
                        duplicateStaffMap = duplicateStaffIdxsForPreset(presets[selectedIndex])
                    } else {
                        duplicateStaffMap = ({})
                    }

                    refreshDuplicateStaffMap()
                    refreshStaffActiveRows()

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
                        icon: IconCode.OPEN_FILE
                        enabled: true
                        toolTipTitle: qsTr("Open / Save presets")
                        onClicked: {
                            let choice = Interactive.question(
                                    qsTr("Open / Save presets?"),
                                    qsTr("Open or save the complete list of presets."),
                                    [qsTr("Open"), qsTr("Save"), qsTr("Cancel")]
                                    )
                            if (!choice || choice === qsTr("Cancel"))
                                return
                            if (choice === qsTr("Open")) {
                                root.openPresetLoadDialog()
                                return
                            }
                            if (choice === qsTr("Save")) {
                                root.openPresetSaveDialog()
                                return
                            }
                        }
                    }

                    FlatButton {
                        id: cardView
                        icon: root.gridView ? IconCode.SPLIT_VIEW_VERTICAL : IconCode.GRID
                        toolTipTitle: qsTr("Toggle preset view")
                        onClicked: {
                            root.gridView = !root.gridView

                        }
                    }

                    FlatButton {
                        id: settingsBtn
                        icon: IconCode.SETTINGS_COG
                        toolTipTitle: qsTr("Preset settings")
                        accentButton: root.settingsOpen
                        onClicked: {
                            root.settingsOpen = !root.settingsOpen

                            try { ocPrefs.lastSettingsOpen = root.settingsOpen; if (ocPrefs.sync) ocPrefs.sync(); } catch (e) {}

                            if (!root.settingsOpen) {
                                savePresetsToSettings()
                            }

                            if (!root.settingsOpen && rootUI) {
                                rootUI.selectedIndex = -1
                            }

                            // When opening settings, auto-select first card if one exists
                            if (root.settingsOpen && rootUI && rootUI.selectedIndex < 0 && allPresetsModel.count > 0) {
                                rootUI.selectedIndex = 0
                                applyPresetToUI(0)
                            }

                            const startW  = orchestratorWin.width
                            const targetW = root.settingsOpen ? (root.baseWidth + 602) : root.baseWidth

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
                                            if (!p) return false;
                                            if (!p.backgroundColor) return false;
                                            return String(p.backgroundColor).length > 0;
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
                                                var suffix = qsTr(" more...")

                                                while (lo <= hi) {
                                                    var mid = Math.floor((lo + hi) / 2)
                                                    var candidate = (mid > 0 ? words.slice(0, mid).join(" ") + suffix : trim(suffix))
                                                    stavesMeasure.text = candidate

                                                    if (stavesMeasure.lineCount <= maxLines) {
                                                        fit = mid
                                                        lo = mid + 1
                                                    } else {
                                                        hi = mid - 1
                                                    }

                                                }

                                                var out = (fit > 0 ? words.slice(0, fit).join(" ") + suffix : trim(suffix))
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
                                            // In normal mode, cards act like momentary buttons
                                            if (!root.settingsOpen) {
                                                // trigger-only, no selection persistence
                                                rootUI.selectedIndex = -1
                                                root.firePreset(model.index)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: settingsSeparator
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: rootUI.right
                anchors.leftMargin: -13 // the same visual inset as before
                width: 1
                color: ui.theme.strokeColor

                // Use a fixed gap
                property int sideGap: 13
            }

            ColumnLayout {
                id: settingsTools
                anchors.left: settingsSeparator.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.leftMargin: settingsSeparator.sideGap
                anchors.topMargin: 12
                anchors.bottomMargin: 12
                spacing: 8

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

                // Unused since all actions trigger preset save
                // FlatButton {
                //     id: presetSaveButton

                //     accentButton: true
                //     icon: IconCode.SAVE
                //     //toolTip: qsTr("Add preset (placeholder)")
                //     onClicked: {
                //         saveCurrentPreset()
                //         __logInfo("Preset saved: " + presetTitleField.text)
                //     }
                // }

                FlatButton {
                    id: newPresetButton
                    icon: IconCode.PLUS
                    toolTipTitle: qsTr("Add preset")
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
                        refreshStaffActiveRows();
                        presetFlick.contentY = 0;

                        // --- 2) Clear ALL selection state in the UI ---
                        root.usedInstView = false;

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
                        np.noteRowsByStableKey = {};
                        notifyPresetsMutated();
                        refreshPresetsListModel();
                        refreshStaffActiveRows();

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
                    toolTipTitle: qsTr("Move preset up")
                    onClicked: {
                        const i = rootUI.selectedIndex
                        const last = allPresetsModel.count - 1
                        if (i <= 0 || i > last) return
                        // Move in the UI
                        allPresetsModel.move(i, i - 1, 1)
                        // Mirror move in presets[]
                        var tmp = presets[i - 1]; presets[i - 1] = presets[i]; presets[i] = tmp
                        notifyPresetsMutated()
                        refreshStaffActiveRows()
                        rootUI.selectedIndex = i - 1
                        settingsTools.scrollCardIntoView(i - 1)
                        savePresetsToSettings()
                    }
                }

                FlatButton {
                    icon: IconCode.ARROW_DOWN
                    enabled: (rootUI.selectedIndex >= 0 && rootUI.selectedIndex < allPresetsModel.count - 1)
                    toolTipTitle: qsTr("Move preset down")
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
                    enabled: (allPresetsModel.count > 0)
                    toolTipTitle: qsTr("Color preset")
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
                        //         refreshStaffActiveRows();
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

                                        p.backgroundColor = colorToHex(swatch);

                                        // Force QML bindings to re-evaluate for the current card
                                        notifyPresetsMutated();
                                        refreshPresetsListModel();
                                        refreshStaffActiveRows();

                                        // Nudge selection to force delegate refresh (handles first-preset case)
                                        var uiRef2 = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                        if (uiRef2 && uiRef2.selectedIndex === sel) {
                                            uiRef2.selectedIndex = -1;
                                            Qt.callLater(function () {
                                                uiRef2.selectedIndex = sel;
                                            });
                                        }

                                        savePresetsToSettings();
                                        popupView.close();
                                    }
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

                                        p.backgroundColor = colorToHex(swatch);

                                        // Force QML bindings to re-evaluate for the current card
                                        notifyPresetsMutated();
                                        refreshPresetsListModel();
                                        refreshStaffActiveRows();

                                        // Nudge selection to force delegate refresh (handles first-preset case)
                                        var uiRef2 = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                        if (uiRef2 && uiRef2.selectedIndex === sel) {
                                            uiRef2.selectedIndex = -1;
                                            Qt.callLater(function () {
                                                uiRef2.selectedIndex = sel;
                                            });
                                        }

                                        savePresetsToSettings();
                                        popupView.close();
                                    }
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

                                        p.backgroundColor = colorToHex(swatch);

                                        // Force QML bindings to re-evaluate for the current card
                                        notifyPresetsMutated();
                                        refreshPresetsListModel();
                                        refreshStaffActiveRows();

                                        // Nudge selection to force delegate refresh (handles first-preset case)
                                        var uiRef2 = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                        if (uiRef2 && uiRef2.selectedIndex === sel) {
                                            uiRef2.selectedIndex = -1;
                                            Qt.callLater(function () {
                                                uiRef2.selectedIndex = sel;
                                            });
                                        }

                                        savePresetsToSettings();
                                        popupView.close();
                                    }
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

                                        p.backgroundColor = colorToHex(swatch);

                                        // Force QML bindings to re-evaluate for the current card
                                        notifyPresetsMutated();
                                        refreshPresetsListModel();
                                        refreshStaffActiveRows();

                                        // Nudge selection to force delegate refresh (handles first-preset case)
                                        var uiRef2 = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                        if (uiRef2 && uiRef2.selectedIndex === sel) {
                                            uiRef2.selectedIndex = -1;
                                            Qt.callLater(function () {
                                                uiRef2.selectedIndex = sel;
                                            });
                                        }

                                        savePresetsToSettings();
                                        popupView.close();
                                    }
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

                                        p.backgroundColor = colorToHex(swatch);

                                        // Force QML bindings to re-evaluate for the current card
                                        notifyPresetsMutated();
                                        refreshPresetsListModel();
                                        refreshStaffActiveRows();

                                        // Nudge selection to force delegate refresh (handles first-preset case)
                                        var uiRef2 = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                        if (uiRef2 && uiRef2.selectedIndex === sel) {
                                            uiRef2.selectedIndex = -1;
                                            Qt.callLater(function () {
                                                uiRef2.selectedIndex = sel;
                                            });
                                        }

                                        savePresetsToSettings();
                                        popupView.close();
                                    }
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

                                        p.backgroundColor = colorToHex(swatch);

                                        // Force QML bindings to re-evaluate for the current card
                                        notifyPresetsMutated();
                                        refreshPresetsListModel();
                                        refreshStaffActiveRows();

                                        // Nudge selection to force delegate refresh (handles first-preset case)
                                        var uiRef2 = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                        if (uiRef2 && uiRef2.selectedIndex === sel) {
                                            uiRef2.selectedIndex = -1;
                                            Qt.callLater(function () {
                                                uiRef2.selectedIndex = sel;
                                            });
                                        }

                                        savePresetsToSettings();
                                        popupView.close();
                                    }
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

                                        p.backgroundColor = colorToHex(swatch);

                                        // Force QML bindings to re-evaluate for the current card
                                        notifyPresetsMutated();
                                        refreshPresetsListModel();
                                        refreshStaffActiveRows();

                                        // Nudge selection to force delegate refresh (handles first-preset case)
                                        var uiRef2 = orchestratorWin ? orchestratorWin.rootUIRef : null;
                                        if (uiRef2 && uiRef2.selectedIndex === sel) {
                                            uiRef2.selectedIndex = -1;
                                            Qt.callLater(function () {
                                                uiRef2.selectedIndex = sel;
                                            });
                                        }

                                        savePresetsToSettings();
                                        popupView.close();
                                    }
                                }
                            }

                            // --- Clear Custom Color Button ---
                            FlatButton {
                                id: clearColorBtn
                                icon: IconCode.DELETE_TANK
                                toolTipTitle: qsTr("Clear color")
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
                                        refreshStaffActiveRows();
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
                    toolTipTitle: qsTr("Copy preset")
                    onClicked: {
                        root.copyCurrentPresetToClipboard()
                    }
                }

                FlatButton {
                    id: pastePresetBtn
                    icon: IconCode.PASTE
                    enabled: root.canPasteIntoCurrentPreset()
                    toolTipTitle: qsTr("Paste preset")
                    onClicked: {
                        root.pasteClipboardIntoCurrentPreset()
                    }
                }

                // Delete selected (with confirmation)
                FlatButton {
                    icon: IconCode.DELETE_TANK
                    enabled: (allPresetsModel.count > 0)
                    toolTipTitle: qsTr("Delete preset")
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

                RowLayout {
                    id: presetHeaderRow
                    Layout.fillWidth: true
                    spacing: 10

                    Layout.fillHeight: false
                    Layout.alignment: Qt.AlignTop

                    Item {
                        id: presetTitleWrap
                        width: stavesBox.width
                        height: newPresetButton.height

                        TextField {
                            id: presetTitleField
                            anchors.fill: parent
                            enabled: rootUI.selectedIndex >= 0 && rootUI.selectedIndex < presets.length
                            placeholderText: qsTr("Preset name")
                            text: qsTr("")
                            font.bold: true
                            selectByMouse: true
                            width: 200
                            leftPadding: 10
                            color: ui.theme.fontPrimaryColor
                            selectionColor: Utils.colorWithAlpha(ui.theme.accentColor, ui.theme.accentOpacityNormal)
                            selectedTextColor: ui.theme.fontPrimaryColor
                            placeholderTextColor: Utils.colorWithAlpha(ui.theme.fontPrimaryColor, 0.3)
                            background: Rectangle {
                                radius: 3
                                color: ui.theme.textFieldColor
                                border.width: 1
                                border.color: presetTitleField.activeFocus ? ui.theme.accentColor : ui.theme.strokeColor
                                opacity: presetTitleField.enabled ? 1.0 : 0.5
                            }
                            Component.onCompleted: {
                                cursorPosition = 0
                                deselect()
                            }
                            onTextEdited: {
                                // Debounced autosave while typing
                                presetNameSaveTimer.restart()
                            }
                            onEditingFinished: {
                                // Flush immediately when focus leaves the field
                                presetNameSaveTimer.stop()
                                root.commitPresetNameOnly()
                            }
                            onAccepted: {
                                // Enter pressed: flush immediately
                                presetNameSaveTimer.stop()
                                root.commitPresetNameOnly()
                            }
                        }

                        Timer {
                            id: presetNameSaveTimer
                            // Don't spam disk writes with each keystroke
                            interval: 350
                            repeat: false
                            onTriggered: root.commitPresetNameOnly()
                        }

                        Item { Layout.fillWidth: true }
                    }

                    FlatButton {
                        id: instView
                        icon: root.usedInstView ? IconCode.SMALL_ARROW_RIGHT : IconCode.SMALL_ARROW_DOWN
                        toolTipTitle: root.usedInstView ? qsTr("All instruments view") : qsTr("Active instruments view")
                        onClicked: {
                            root.usedInstView = !root.usedInstView
                        }
                    }
                }

                // Keyboard handling at the container level: treat staves list as the focus target
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function (event) {
                    // Only act when the staves panel has focus (list or its scrollview)
                    var stavesFocused = (staffList && staffList.activeFocus) || (stavesScroll && stavesScroll.activeFocus)
                    if (!stavesFocused) return

                    var isShift = !!(event.modifiers & Qt.ShiftModifier)
                    var isCtrl  = !!(event.modifiers & Qt.ControlModifier)
                    var isCmd   = !!(event.modifiers & Qt.MetaModifier)

                    // Select all staves
                    if ((isCtrl || isCmd) && event.key === Qt.Key_A) {
                        selectAll()
                        if (staffList.currentIndex < 0)
                            staffList.currentIndex = firstVisibleStaffRowIndex()
                        event.accepted = true
                        return
                    }

                    // Extend selection
                    if (isShift && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
                        var step = (event.key === Qt.Key_Up) ? -1 : 1
                        var startIdx = (staffList.currentIndex >= 0)
                                ? staffList.currentIndex
                                : (step > 0 ? firstVisibleStaffRowIndex() : lastVisibleStaffRowIndex())
                        var idx = nextVisibleStaffRowIndex(startIdx, step)
                        if (idx >= 0) {
                            selectRange(idx)
                            staffList.currentIndex = idx
                        }
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
                        if (staffList.currentIndex < 0)
                            staffList.currentIndex = firstVisibleStaffRowIndex()
                    }
                }

                Shortcut {
                    id: scShiftUp
                    context: Qt.WindowShortcut
                    enabled: (staffListModel.count > 0)
                    sequences: [ "Shift+Up" ]
                    onActivated: {
                        var cur = (staffList.currentIndex >= 0) ? staffList.currentIndex : lastVisibleStaffRowIndex()
                        var next = nextVisibleStaffRowIndex(cur, -1)
                        if (next < 0)
                            return
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
                        var cur = (staffList.currentIndex >= 0) ? staffList.currentIndex : firstVisibleStaffRowIndex()
                        var next = nextVisibleStaffRowIndex(cur, 1)
                        if (next < 0)
                            return
                        if (lastAnchorIndex < 0) lastAnchorIndex = cur
                        selectRange(next)
                        staffList.currentIndex = next
                    }
                }

                RowLayout {
                    id: listAndButtonsRow

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: settingsUI.anchors.leftMargin

                    // --- Left: Staves multi-select list ---
                    GroupBox {
                        id: stavesBox
                        Layout.alignment: Qt.AlignTop
                        Layout.fillHeight: true

                        Layout.preferredWidth:  200
                        Layout.maximumWidth:    200
                        Layout.minimumWidth:    200

                        Layout.maximumHeight: staffList ? staffList.contentHeight : 0
                        Layout.preferredHeight: Math.min(
                                                    staffList ? staffList.contentHeight : 0,
                                                    settingsUI.height - 24 // Leave the panel's margins/spacing
                                                    )

                        padding: 0
                        background: Rectangle { color: ui.theme.backgroundPrimaryColor }

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
                                spacing: root.usedInstView ? 0 : 8
                                delegate: Item {
                                    id: rowShell
                                    property bool hasActiveRows: model.hasActiveRows
                                    property bool rowVisible: !root.usedInstView || hasActiveRows

                                    property bool isDuplicateTarget: (
                                                                         root.settingsOpen &&
                                                                         !!root.duplicateStaffMap &&
                                                                         !!root.duplicateStaffMap[model.idx]
                                                                         )

                                    visible: rowVisible
                                    width: ListView.view.width
                                    height: rowVisible ? (root.usedInstView ? 38 : 30) : 0

                                    ItemDelegate {
                                        id: rowDelegate
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        height: 30
                                        leftPadding: 10

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
                                            color: rowShell.isDuplicateTarget ? "#FF0000" : ui.theme.accentColor
                                            visible: rowShell.hasActiveRows || rowShell.isDuplicateTarget

                                            z: 10

                                            FlatButton {
                                                id: instStripTooltip
                                                toolTipTitle: rowShell.isDuplicateTarget ? qsTr("Duplicate instrument") : qsTr("Assigned instrument")
                                                transparent: true
                                                hoverHitColor: "transparent"
                                                onClicked: {}
                                                width: parent.width
                                                height: parent.height
                                            }
                                        }

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
                                                var ctrlOrCmd = (mouse.modifiers & Qt.ControlModifier) ||
                                                        (mouse.modifiers & Qt.MetaModifier)
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
                                }

                                Keys.onPressed: function (event) {
                                    const isCmd = !!(event.modifiers & Qt.MetaModifier)
                                    const isCtrl = !!(event.modifiers & Qt.ControlModifier)
                                    const isShift = !!(event.modifiers & Qt.ShiftModifier)

                                    if ((isCmd || isCtrl) && event.key === Qt.Key_A) {
                                        selectAll()
                                        if (staffList.currentIndex < 0)
                                            staffList.currentIndex = firstVisibleStaffRowIndex()
                                        event.accepted = true
                                        return
                                    }

                                    if (event.key === Qt.Key_Up) {
                                        var startIdx = (staffList.currentIndex >= 0) ? staffList.currentIndex : lastVisibleStaffRowIndex()
                                        var idx = nextVisibleStaffRowIndex(startIdx, -1)
                                        if (idx >= 0) {
                                            if (isShift) selectRange(idx); else selectSingle(idx)
                                            staffList.currentIndex = idx
                                            // keep current staff selection; just reload rows for the new focus
                                            if (rootUI.selectedIndex >= 0)
                                                applyPresetToUI(rootUI.selectedIndex, { preserveStaffSelection: true })
                                        }
                                        event.accepted = true
                                        return
                                    }

                                    if (event.key === Qt.Key_Down) {
                                        var startIdx2 = (staffList.currentIndex >= 0) ? staffList.currentIndex : firstVisibleStaffRowIndex()
                                        var idx2 = nextVisibleStaffRowIndex(startIdx2, 1)
                                        if (idx2 >= 0) {
                                            if (isShift) selectRange(idx2); else selectSingle(idx2)
                                            staffList.currentIndex = idx2
                                            // keep current staff selection; just reload rows for the new focus
                                            if (rootUI.selectedIndex >= 0)
                                                applyPresetToUI(rootUI.selectedIndex, { preserveStaffSelection: true })
                                        }
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

                    // --- Right: 8-note multi-select button column ---
                    Item {
                        id: noteButtonsPane
                        Layout.alignment: Qt.AlignTop
                        Layout.fillHeight: true

                        visible: true

                        readonly property bool hasFocusedStaff: (
                                                                    orchestratorWin &&
                                                                    orchestratorWin.staffListRef &&
                                                                    orchestratorWin.staffListRef.currentIndex >= 0
                                                                    )

                        // Dropdown width probe (measure "+36" using the actual StyledDropdown font)
                        StyledDropdown { id: _ddProbe; visible: false } // Font may be undefined early
                        FontMetrics {
                            id: _ddFM
                            font: (_ddProbe && _ddProbe.font) ? _ddProbe.font : Qt.font({})
                        }
                        // Text width of "+36" + indicator allowance
                        property int ddMinWidth: Math.ceil(_ddFM.advanceWidth("+36")) + 46

                        FlatButton { id: _voice1Probe; icon: IconCode.VOICE_1; visible: false }
                        FlatButton { id: _voice2Probe; icon: IconCode.VOICE_2; visible: false }
                        FlatButton { id: _voice3Probe; icon: IconCode.VOICE_3; visible: false }
                        FlatButton { id: _voice4Probe; icon: IconCode.VOICE_4; visible: false }

                        readonly property int noteButtonWidth: 120
                        readonly property int rowLeftInset: 5
                        readonly property int rowGap: listAndButtonsRow.spacing + 15
                        readonly property int voiceButtonsWidth:
                            _voice1Probe.implicitWidth +
                            _voice2Probe.implicitWidth +
                            _voice3Probe.implicitWidth +
                            _voice4Probe.implicitWidth
                        readonly property int rowRightPad: 4

                        readonly property int expandedPaneWidth:
                            rowLeftInset +
                            noteButtonWidth +
                            rowGap +
                            ddMinWidth +
                            voiceButtonsWidth +
                            rowRightPad

                        enabled: hasFocusedStaff
                        Layout.preferredWidth: noteButtonsReveal.width
                        Layout.maximumWidth: noteButtonsReveal.width
                        Layout.minimumWidth: noteButtonsReveal.width

                        Item {
                            id: noteButtonsReveal
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            width: noteButtonsPane.hasFocusedStaff ? noteButtonsPane.expandedPaneWidth : 0
                            opacity: noteButtonsPane.hasFocusedStaff ? 1.0 : 0.0
                            clip: true
                            enabled: noteButtonsPane.hasFocusedStaff

                            Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                            Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                        }

                        // Multi-select state & helpers
                        // Row index -> true when selected
                        property var selectedNotes: ({})

                        // Anchor for Shift-range operations
                        property int lastAnchorNoteIndex: -1

                        function clearNoteSelection() {
                            selectedNotes = ({})
                            root.scheduleLiveCommit()
                        }

                        property var pitchIndexByRow: ({})

                        // Voice selection state (one voice per row; independent per row)
                        // Row index -> 0|1|2|3 (selected voice), or undefined for none
                        property var voiceByRow: ({})

                        function setVoiceForRow(rowIndex, v) {
                            // Disallow "no voice": clicking the same voice keeps it selected.
                            var vv = (v === 0 || v === 1 || v === 2 || v === 3) ? v : 0
                            var m = Object.assign({}, voiceByRow)
                            m[rowIndex] = vv
                            voiceByRow = m

                            // Live-commit after voice change
                            root.scheduleLiveCommit()
                        }

                        Component.onCompleted: {
                            var m = {}
                            for (var i = 0; i < noteButtonsModel.count; ++i) {
                                m[i] = root.pitchCenterIndex // default 0 semitones
                            }
                            pitchIndexByRow = m
                            // (voiceByRow initialization below)
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
                            ListElement { name: qsTr("Top / Single note") }
                            ListElement { name: qsTr("Seventh note") }
                            ListElement { name: qsTr("Sixth note") }
                            ListElement { name: qsTr("Fifth note") }
                            ListElement { name: qsTr("Fourth note") }
                            ListElement { name: qsTr("Third note") }
                            ListElement { name: qsTr("Second note") }
                            ListElement { name: qsTr("Bottom note") }

                            // If rows are ever added later, default them to voice 0 (UI voice 1)
                            onCountChanged: {
                                var m = Object.assign({}, noteButtonsPane.voiceByRow)
                                for (var i = 0; i < noteButtonsModel.count; ++i) {
                                    if (m[i] === undefined) m[i] = 0
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

                        // Each row contains a Note button, Pitch dropdown, and Voice button delegate
                        ListView {
                            id: noteButtonsView
                            parent: noteButtonsReveal
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
                                width: noteButtonsView.width
                                height: _btnProbe.implicitHeight

                                Row {
                                    id: rowContent
                                    anchors {
                                        left: parent.left
                                        leftMargin: 5   // Keep external gap equal to RowLayout spacing
                                        verticalCenter: parent.verticalCenter
                                    }
                                    spacing: listAndButtonsRow.spacing + 5 // Align with note buttons

                                    // Left: the note button
                                    FlatButton {
                                        id: noteBtn
                                        width: 120
                                        height: _btnProbe.implicitHeight
                                        text: model.name
                                        // Multi-select: accent when selected
                                        property bool isActive: !!noteButtonsPane.selectedNotes[index]
                                        accentButton: isActive
                                        transparent: false

                                        // Accent strip inside the button, on left edge
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
                                                if (!p || !p.noteRowsByStableKey) return false;
                                                for (var stableKey in p.noteRowsByStableKey) {
                                                    if (!p.noteRowsByStableKey.hasOwnProperty(stableKey)) continue;
                                                    var rows = presetRowsForStableKey(p, stableKey);
                                                    if (index >= 0 && index < rows.length && rows[index] && rows[index].active)
                                                        return true;
                                                }
                                                return false;
                                            }
                                            z: 1

                                            FlatButton {
                                                id: noteStripTooltip
                                                toolTipTitle: qsTr("Assigned note")
                                                transparent: true
                                                hoverHitColor: "transparent"
                                                onClicked: {}
                                                width: parent.width
                                                height: parent.height
                                            }
                                        }

                                        onClicked: function (mouse) {
                                            var ctrlOrCmd = (mouse.modifiers & Qt.ControlModifier)
                                                    || (mouse.modifiers & Qt.MetaModifier)
                                            var isShift = (mouse.modifiers & Qt.ShiftModifier)
                                            if (isShift) {
                                                // Shift = extend selection to range
                                                noteButtonsPane.selectRangeNote(index)
                                            } else if (ctrlOrCmd) {
                                                // Cmd/Ctrl = explicit toggle
                                                noteButtonsPane.toggleNote(index)
                                            } else {
                                                // Plain click = toggle on/off
                                                noteButtonsPane.toggleNote(index)
                                            }
                                            // Keep keyboard focus/anchor behavior the same
                                            noteButtonsView.currentIndex = index
                                        }
                                    }

                                    // Right: chromatic pitch transformer dropdown and voice toggles
                                    // Default row to -- (no pitch change) and Voice 0 (1 in UI)
                                    // Pitch dropdown index 0..72, 36 = "--", (+36…--…-36)
                                    // Voice button index 0-3 (1-4 in UI)
                                    // Shown only when note button is active
                                    Item {
                                        id: ddWrap
                                        height: _btnProbe.implicitHeight
                                        // Animate width/opacity for a smooth reveal
                                        width: noteBtn.isActive ? noteButtonsPane.ddMinWidth : 0
                                        opacity: noteBtn.isActive ? 1.0 : 0.0
                                        enabled: noteBtn.isActive
                                        clip: true
                                        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                                        Behavior on opacity{ NumberAnimation { duration: 250; easing.type: Easing.InOutQuad } }
                                        StyledDropdown {
                                            id: pitchShift
                                            anchors.fill: parent
                                            // +36..+1 -- -1..-36
                                            model: (function () {
                                                var items = [], i
                                                for (i = root.pitchOffsetMax; i >= 1; --i) items.push({ text: "+" + i, value: i })
                                                items.push({ text: "--", value: 0 })
                                                for (i = -1; i >= -root.pitchOffsetMax; --i) items.push({ text: "" + i, value: i })
                                                return items
                                            })()
                                            currentIndex: (noteButtonsPane.pitchIndexByRow[index] !== undefined)
                                                          ? noteButtonsPane.pitchIndexByRow[index] : root.pitchCenterIndex
                                            onActivated: function(ix, value) {
                                                var selectedValue = Number(value)
                                                if (isNaN(selectedValue)) {
                                                    selectedValue = root.pitchIndexToValue(ix)
                                                }
                                                var normalizedIndex = root.pitchValueToIndex(selectedValue)
                                                var m = Object.assign({}, noteButtonsPane.pitchIndexByRow)
                                                m[index] = normalizedIndex
                                                noteButtonsPane.pitchIndexByRow = m
                                                // Live-commit after pitch change
                                                root.scheduleLiveCommit()
                                            }
                                        }
                                    }

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

                                        Row {
                                            id: voiceRow
                                            spacing: 0 // Voice button edges touch to avoid unnatural spacing

                                            FlatButton {
                                                id: voice1Btn
                                                icon: IconCode.VOICE_1
                                                property bool selected: (noteButtonsPane.voiceByRow[index] === 0)
                                                accentButton: selected
                                                transparent: !selected
                                                onClicked: noteButtonsPane.setVoiceForRow(index, 0)
                                            }

                                            FlatButton {
                                                id: voice2Btn
                                                icon: IconCode.VOICE_2
                                                property bool selected: (noteButtonsPane.voiceByRow[index] === 1)
                                                accentButton: selected
                                                transparent: !selected
                                                onClicked: noteButtonsPane.setVoiceForRow(index, 1)
                                            }

                                            FlatButton {
                                                id: voice3Btn
                                                icon: IconCode.VOICE_3
                                                property bool selected: (noteButtonsPane.voiceByRow[index] === 2)
                                                accentButton: selected
                                                transparent: !selected
                                                onClicked: noteButtonsPane.setVoiceForRow(index, 2)
                                            }

                                            FlatButton {
                                                id: voice4Btn
                                                icon: IconCode.VOICE_4
                                                property bool selected: (noteButtonsPane.voiceByRow[index] === 3)
                                                accentButton: selected
                                                transparent: !selected
                                                onClicked: noteButtonsPane.setVoiceForRow(index, 3)
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
                                text: qsTr("Delete preset?")
                                font.pixelSize: 16
                                font.bold: true
                                color: ui.theme.fontPrimaryColor
                            }

                            // Message text
                            Label {
                                text: dlg.messageText
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
