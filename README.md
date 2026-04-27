# Orchestrator
A preset system to quickly orchestrate sketches in MuseScore Studio 4.7+

<img width="913" height="686" alt="score_with_orchestrator_window" src="https://github.com/user-attachments/assets/9692d321-7c90-4b01-88e8-6929e04b0a2a" />

Developed with ❤️ by Eric Warren
  
> [!CAUTION]
> The MuseScore 4.7 betas are considered stable, but there may be bugs which affect Orchestrator. Once MuseScore 4.7 is officially released, I'll address any issues.





## Setup
1. Download the latest release from the panel on the right. Unzip to your MuseScore Plugins directory. (Documents/MuseScore4/Plugins)
2. Click Home > Plugins and enable Orchestrator.
   
   <img width="613" height="443" alt="plugins_enabled" src="https://github.com/user-attachments/assets/8eed106a-4c2a-4735-a46b-aae56a2b4665" />

> [!TIP]
> Set a keyboard shortcut in MuseScore's Preferences > Shortcuts panel. Search for "orchestrator" and define a shortcut. For example, ⌘⇧+O.

3. Open the Orchestrator plugin and click the Settings (gear) icon. In the Settings section, click Add to create a new preset. Rename it, select an instrument and assign notes and pitch modifications as needed. Repeat this process for to create additional presets.

   Move the selected preset up or down with the Arrow buttons. Assign a color with the Brush button. Copy and Paste a preset to a new empty preset. Delete a preset with the Trash button.

   <img width="902" height="516" alt="orchestrator_settings" src="https://github.com/user-attachments/assets/7869e22f-a16b-4924-a0f2-799e8fbe95db" />

> [!TIP]
> Select multiple instruments with Cmd/Ctrl+click to quickly assign them to the same note. Also, click the triangle button to the right of the preset name to toggle a compact view of only the instruments used by the preset.

4. Close the Settings panel. Each preset card includes the preset name, number of chord notes, and a list of instruments. Use the Filter to search for a preset or instrument. Change to a compact view with the button filled with squares.

   <img width="300" height="514" alt="orchestrator_presets" src="https://github.com/user-attachments/assets/7822c0ee-cd13-4f10-b2e5-b8069af81ebb" />

   Make a selection in the score from a sketch staff and click a preset button to run the preset. 

   Before
   <img width="1331" height="687" alt="before" src="https://github.com/user-attachments/assets/26de64f8-6261-466f-be9b-6400898557ec" />

   After
   <img width="1290" height="761" alt="after" src="https://github.com/user-attachments/assets/061e65c6-4a9a-49fb-afb4-761c133cd590" />




   


## Known Issues
Currently, a design constraint is that presets operations are based on an instrument's staff index. So presets made for one score layout, won’t necessarily translate to a different score layout. For example, presets made for the Classical Orchestra template won’t completely translate to the Symphony Orchestra template. The instruments, their order, and number of staves, don’t match. I'm working on a design that uses semi-unique identifiers based on `musicXmlId|normalizedstaffname|staffindex` that will map across score layouts.

Changing voices and selecting multiple voices in an instrument sometimes produces wrong results or crashes MuseScore. It's a work-in-progress. For now, I recommend leaving all settings on the default Voice 1.

View known issues on [GitHub](https://github.com/eakwarren/Orchestrator/issues)


## To Do
If you have a suggestion, or find a bug, please report it on [GitHub](https://github.com/eakwarren/Orchestrator/issues). I don’t promise a fix or tech support, but I’m happy to take a look. 🙂




## Special Thanks
_“If I have seen further, it is by standing on the shoulders of Giants.” ~Isaac Newton_

MuseScore Studio developers, wherever they may roam.




## Release Notes
v0.2.6 4/27/26
- Initial beta release
