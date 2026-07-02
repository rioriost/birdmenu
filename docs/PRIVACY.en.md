# BirdMenu Privacy Policy

Last updated: June 29, 2026

BirdMenu is a macOS menu bar app for displaying readings from compatible Bluetooth Low Energy thermometer/hygrometer sensors.

## Summary

BirdMenu does not collect, transmit, sell, share, or track personal data. The app does not use analytics, advertising SDKs, tracking SDKs, or third-party data services.

All Bluetooth readings and history files are processed and stored locally on your Mac.

## Data Processed Locally

BirdMenu may process the following data from nearby compatible sensors:

- temperature
- humidity
- battery level
- Bluetooth signal strength (RSSI)
- Bluetooth device name and local peripheral identifier
- timestamps for readings and history records
- raw Bluetooth packets needed to debug and decode device history

This data is used only to display readings in the macOS menu bar and, when requested, to export device history.

## Local Storage

When you use the experimental history fetch feature, BirdMenu writes files under:

```text
~/Documents/BirdMenu Logs/
```

These files may include:

- `raw-history.json`
- `history.csv`
- `history_yyyymmdd.png`

If debug logging is enabled in the app menu, BirdMenu may also write received Bluetooth readings and packet details to macOS Unified Logging. These logs remain on your Mac and are managed by macOS.

## Data Sharing

BirdMenu does not send Bluetooth readings, history exports, logs, device identifiers, or usage information to the developer or to any third party.

## Network Use

BirdMenu does not require an internet connection for its app functionality.

## Bluetooth Permission

BirdMenu requests Bluetooth access so it can discover and communicate with compatible sensors.

## Data Deletion

You can delete exported history files at any time by removing files from:

```text
~/Documents/BirdMenu Logs/
```

You can clear macOS system logs using the tools provided by macOS.

## Apple Diagnostics

If you choose to share analytics or crash reports with Apple at the system level, Apple may provide diagnostics through Apple developer tools. BirdMenu does not independently collect or transmit crash reports.

## Contact

For privacy questions, open an issue at:

https://github.com/rioriost/birdmenu/issues

Compatibility testing has been performed with INKBIRD ITH-11-B hardware. BirdMenu is not affiliated with or endorsed by INKBIRD.
