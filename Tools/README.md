# MusiCards library indexer

`generate_library.py` creates the shared `library.json` used by the MusiCards
web, macOS and iOS apps. It is the Windows/command-line route: it reads Picard
tags from FLAC and M4A files without loading cover art or audio samples and has
no third-party Python dependencies.

## Usage

Run the script on Windows, macOS or another computer where the music collection
is available offline:

```sh
python3 generate_library.py "/path/to/Music"
```

On Windows, the standard Python launcher can be used:

```powershell
py generate_library.py "D:\Music"
```

The default output is `/path/to/Music/library.json`. To write elsewhere:

```sh
python3 generate_library.py "/path/to/Music" --output "/path/to/library.json"
```

The first run reads the metadata of every supported file. Later runs reuse
unchanged album entries by comparing filename, file size and modification time.
Writing is atomic, so an interrupted run does not damage the previous index.
Folders without a MusicBrainz Release MBID are omitted and summarized when the
run finishes.

Supported containers:

- FLAC
- M4A containing ALAC or AAC

For MusicBrainz matching, files must be tagged with MusicBrainz Picard and have
both a release MBID and recording MBID. The generated JSON deliberately contains
relative paths and no credentials or machine-specific absolute paths.

## Connecting from MusiCards

The intended workflows are:

- Windows: generate `library.json` with this script, then connect the folder in
  the MusiCards web app.
- macOS: use **Create / Update Library Index** to generate and connect in one
  step, or use **Connect Music Folder** for an existing index.
- iPhone: use **Connect Music Folder** with an existing index. iOS does not
  generate one.

Keep `library.json` in the selected music folder. In MusiCards, open Player and
choose **Connect Music Folder**. Selecting the same folder reloads its index;
selecting another folder replaces the previous connection.

MusiCards for Mac can also create the same manifest without Python. Choose
**Create / Update Library Index**, then select the offline music folder. The app
writes `library.json` and connects it automatically. Later updates reuse albums
whose filenames, sizes and modification dates have not changed.

On iOS, MusiCards reads only `library.json` while connecting. It does not scan or
download the complete music collection, and it never generates the index. An
individual remote audio file is needed only when that track is selected for
playback.
