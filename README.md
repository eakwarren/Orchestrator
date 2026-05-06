# Orchestrator
A preset system to quickly orchestrate sketches in MuseScore Studio 4.7+

https://github.com/user-attachments/assets/419d59cd-750a-4cd0-93bd-b69cb6eb9e18

Developed with ❤️ by Eric Warren
  
> [!CAUTION]
> The MuseScore 4.7 betas are considered stable, but there may be bugs which affect Orchestrator. Once MuseScore 4.7 is officially released, I'll address any issues.





## Setup
1. Download the latest release from the panel on the right. Unzip to your MuseScore Plugins directory. (Documents/MuseScore4/Plugins)
2. Click Home > Plugins and enable Orchestrator.
   
   <img width="613" height="443" alt="plugins_enabled" src="https://github.com/user-attachments/assets/8eed106a-4c2a-4735-a46b-aae56a2b4665" />

> [!TIP]
> Set a keyboard shortcut in MuseScore's Preferences > Shortcuts panel. Search for "orchestrator" and define a shortcut. For example, ⌘⇧+O.

3. Open the Orchestrator plugin and click the Settings (gear) button. In the Settings section, click Add to create a new preset. Rename it, select an instrument and assign notes and pitch modifications as needed. Repeat this process for to create additional presets.

   Move the selected preset up or down with the Arrow buttons. Assign a color with the Brush button. Copy and Paste a preset to a new empty preset. Delete a preset with the Trash button. Click the triangle button to the right of the preset name to toggle a compact view of only the instruments used by the preset.

   <img width="902" height="516" alt="settings_window" src="https://github.com/user-attachments/assets/e6806381-c746-48c3-a907-fa0302eb7816" />

   Orchestrator presets stay attached to the same score instruments even if you reorder the score. If you rename, replace, split, merge, or remove instruments, unresolved mappings will be skipped. Duplicate instruments are marked with a red sidebar.

   <img width="286" height="122" alt="duplicate_icons" src="https://github.com/user-attachments/assets/ac479394-94b0-4fcd-b10d-e75ece37d7f0" />

   
> [!TIP]
> Select multiple instruments with Cmd/Ctrl+click to quickly assign them to the same note.

4. Close the Settings panel. Each preset card includes the preset name, number of chord notes, and a list of instruments.

   Use the Filter to search for a preset or instrument. Open or Save preset collections with the folder button. Toggle a compact view with the rectangles button.

   <img width="300" height="514" alt="plugin_window" src="https://github.com/user-attachments/assets/89b3a03c-0dd8-4976-95f7-719cefbc49d6" />

   Make a selection in the score from a sketch staff and click a preset button to run the preset. 

   Before
   <img width="1331" height="687" alt="score_before" src="https://github.com/user-attachments/assets/f293dd91-3046-49f8-a6b8-f6565179da39" />

   After
   <img width="1290" height="761" alt="score_after" src="https://github.com/user-attachments/assets/c0e795ff-fb45-494a-a887-8ee3225fa162" />





   


## Known Issues

> [!CAUTION]
> Changing voices or selecting multiple voices in an instrument sometimes produces wrong results or crashes MuseScore. I'll investigate more once MuseScore 4.7 is released.  For now, I recommend leaving all presets on the default Voice 1.

View known issues on [GitHub](https://github.com/eakwarren/Orchestrator/issues)


## To Do
If you have a suggestion, or find a bug, please report it on [GitHub](https://github.com/eakwarren/Orchestrator/issues). I don’t promise a fix or tech support, but I’m happy to take a look. 🙂




## Special Thanks
_“If I have seen further, it is by standing on the shoulders of Giants.” ~Isaac Newton_

MuseScore Studio developers, wherever they may roam.




## Release Notes
v0.2.9 5/6/26
- open / save preset collections
- auto-refresh instrument lists
- support for reordered score instruments
- duplicate instrument indicators


v0.2.6 4/27/26
- Initial beta release
