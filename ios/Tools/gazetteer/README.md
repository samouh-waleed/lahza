# Gazetteer data

`ios/Packages/LahzaKit/Sources/LZGeo/Resources/cities15000.lzgz` is Lahza's offline place list: city, region,
country and time zone for a GPS position, and the place names the search parser recognises. It is built from
GeoNames and committed; the GeoNames dump itself is not.

## Source

- [GeoNames](https://www.geonames.org) export dump, <https://download.geonames.org/export/dump/>:
  `cities15000.zip` (unzipped to `cities15000.txt`: places of 15,000+ people, plus capitals and city
  sections) and `admin1CodesASCII.txt` (first-level regions).
- Dump of 2026-10-28. Input SHA-256:
  - `cities15000.txt` `60ccddf9f7c6de10356a5d37337b9f8cab01ceb96f1eae7fb1e2c5af12188a77`
  - `admin1CodesASCII.txt` `2e4867f5397acb056ea26377601b57af37cb4c81399770225018e9e439e91ad3`
- Output: 34,164 places, 1,598,958 bytes, SHA-256
  `5bad6b7d7618b186df57a77c0f2f1ad14e2d5482a28f5128a738d4dbc51f28cd`.

## Licence

GeoNames data is licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/)
(CC BY 4.0). The app's Acknowledgements screen credits it in its Data section as "GeoNames" (linking to
geonames.org) with "Place names · CC BY 4.0 · data as of 28 Oct 2026", the date read from the bundled file.
The attribution and licence link ship in `ios/Resources/Licenses/GeoNames-CC-BY-4.0.txt`.

Changes made to the data: historical, abandoned and destroyed places (PPLH, PPLQ, PPLW) are dropped; each place
keeps its name, position, population, feature class, country, region and time zone; English alternate names are
selected (places of 100,000+ people and capitals, up to 8 each) and the curated names in `aliases-en.tsv` are
added; everything is re-encoded in Lahza's binary `LZGZ` format.

## Rebuilding

1. Download and unzip the two files above into one folder (data only; nothing there is run).
2. From `ios/`: `make gazetteer GEONAMES=<that folder>` (set `GEONAMES_DATE=yyyymmdd` for a newer dump).

`lz-gazetteer` (`Packages/LahzaKit/Sources/LZGazetteerTool`) validates every time zone, re-reads 1,000 random
places to check the file, fails above 2,000,000 bytes and warns above 1,800,000. It prints each section's size
and the SHA-256; the same inputs always give the same bytes. After a rebuild, update the numbers above and the
dump date in `GeoNames-CC-BY-4.0.txt`, then run `make test` (the gazetteer tests pin the place count, a table of
verified lookups and the dump date).

`aliases-en.tsv` holds English names people type that GeoNames misses or the automatic filter drops (Mecca,
Medina, Diriyah, Heraklion…). Each row is `geonameid⇥alias|alias⇥display name`; the tool checks the display
name, so a wrong id fails the build.
