sos4lml
=======

Import LML data to a SOS server.

LML: Dutch Air Quality measurement sensor network.

This set of scripts enables easy and fast import of the LML data (as it is exposed via HTTP) to a SOS server. The scripts need a configuration file with the database connection information (sos\_config.py), as well as further configuration in the database table 'configuration'. Also the station, sensor, unit and uri configuration must be provided in order to work. The 'statsensunit' table should contain combinations of stations, sensors and units.
