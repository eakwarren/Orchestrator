# Orchestrator
A preset system to quickly orchestrate sketches in MuseScore Studio 4.7+

> [!CAUTION]
> The MuseScore 4.7 betas are considered stable, but there may be bugs which affect Orchestrator. Once MuseScore 4.7 is officially released, I'll address any issues.


Developed with ❤️ by Eric Warren

## Setup
1. Download the latest release from the panel on the right. Unzip to your MuseScore Plugins directory. (Documents/MuseScore4/Plugins)
2. Enable the plugin in MuseScore Studio under Plugins > Manage plugins. Click the plugin and click Enable. 

> [!TIP]
> Set a keyboard shortcut in MuseScore's Preferences > Shortcuts panel. Search for "orchestrator" and define a shortcut. For example, ⌘⇧+O.

3. Open the Orchestrator plugin and click the Settings (gear) icon. In the Settings section, click + to create a new preset. Rename it, select an instrument and assign notes and pitch modifications as needed. Repeat this process for to create additional presets.

> [!TIP]
> Select multiple instruments with Cmd/Ctrl+click to quickly assign them to the same keyswitch set.

4. Close the Settings panel. Make a selection in the score from a sketch staff and click a preset button to run the preset.
   


## Known Issues

Currently, a design constraint is that presets operations are based on an instrument's staff index. So presets made for one orchestral score layout, won’t necessarily translate to a different score layout. For example, presets made for the Classical Orchestra template won’t completely translate to the Symphony Orchestra template. The instruments, their order, and number of staves, don’t match. I'm working on a design that uses semi-unique identifiers based on `musicXmlId|normalizedstaffname|staffindex` that will map across score layouts.

View known issues on [GitHub](https://github.com/eakwarren/Orchestrator/issues)


## To Do
If you have a suggestion, or find a bug, please report it on [GitHub](https://github.com/eakwarren/Orchestrator/issues). I don’t promise a fix or tech support, but I’m happy to take a look. 🙂




## Special Thanks
_“If I have seen further, it is by standing on the shoulders of Giants.” ~Isaac Newton_

MuseScore Studio developers, wherever they may roam.




## Release Notes
TBD
