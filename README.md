sos4lml
=======

Imports XML data from http download to a SOS server.

Targets the LML xml for SOS source format (LML=the Dutch Air Quality measurement sensor network). With very little effort the XML reader can be adapted to other source schema's, also using it without XML with custom sources is very well possible.

This set of scripts enables easy and fast import of the LML data (as it is exposed via HTTP) to a SOS server. The scripts need a configuration file with the database connection information (sos\_config.py), as well as further configuration in the database table 'configuration'. Also the station, sensor, unit and uri configuration must be provided in order to work. The 'statsensunit' table should contain combinations of stations, sensors and units.

Characteristics:
* Fast: 5000+ XML files, containing 150,000+ measurenents can be downloaded, processed and published within a few minutes. A typical hourly update takes place in 1 or 2 seconds.
* Configurable which stations and sensors will be published.
* Automatic efficient retry mechanism for failed downloads (e.g. data not available at time of download, network failures).
* Capable of dealing with updates from the source.
* No load on the SOS server for loading new data, it doesn't even have to be running.
* No frameworks needed: runs on plain Postgres (9.x) + PostGIS (2.x) and a stock Python 2.7 (with some standard extensions, like urllib, urllib2, uiud, time, psycopg2).
* Configurable uri identifiers for sensors, features of interest and observations.
* Possibility to restore from cache to SOS using the originally provided identifiers, or republish using new identifiers.
* Entire configuration resides in the database for remote management.
* Preparation of the SOS server is done using the SOS-T (json) interface, this minimizes the chance that the lml_import procedures need maintenance with new releases of the SOS server.
