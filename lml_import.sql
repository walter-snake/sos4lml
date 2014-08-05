--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

--
-- Name: lml_import; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA lml_import;


SET search_path = lml_import, pg_catalog;

--
-- Name: download_failures_insert(); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION download_failures_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (SELECT EXISTS (SELECT 1 FROM lml_import.download_failures WHERE filename = NEW.filename)) THEN
    RETURN NULL;
  ELSE
    RETURN NEW;
  END IF;
END;
$$;


--
-- Name: getseriesid(text, text, text); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION getseriesid(foi_identifier text, obsprop_identifier text, proc_identifier text) RETURNS bigint
    LANGUAGE sql
    AS $_$
select s.seriesid
-- , s.featureofinterestid, s.observablepropertyid, s.procedureid
from sos.series s
join sos.featureofinterest f
  on f.featureofinterestid = s.featureofinterestid
join sos.observableproperty o
  on o.observablepropertyid = s.observablepropertyid
join sos.procedure p
  on p.procedureid = s.procedureid
where f.identifier = $1
  and o.identifier = $2
  and p.identifier = $3
;
$_$;


--
-- Name: getstationid(text); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION getstationid(station_code text) RETURNS bigint
    LANGUAGE sql
    AS $$
select id
from lml_import.vw_stations
where stationcode = station_code;
$$;


--
-- Name: insertobservation(bigint, text, text, double precision, text, timestamp with time zone, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION insertobservation(mseriesid bigint, publishstatcode text, sensorcode text, mvalue double precision, munit text, timestart timestamp with time zone, timeend timestamp with time zone, result_time timestamp with time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  -- uri bases
  ub_sensor text;
  ub_foi text;
  ub_obsprop text;
  ub_offer text;
  ub_obs text;

  -- ids
  offer_id bigint;
  unit_id bigint;
  series_id bigint;
  codespace_id bigint;

  -- result: observation id
  obs_uri text;
  obs_id bigint;
BEGIN
  -- get the various uri-bases
  SELECT uri INTO ub_sensor FROM lml_import.uribase WHERE key = 'procedure';
  SELECT uri INTO ub_foi FROM lml_import.uribase WHERE key = 'featureofinterest';
  SELECT uri INTO ub_obsprop FROM lml_import.uribase WHERE key = 'observableproperty';
  SELECT uri INTO ub_offer FROM lml_import.uribase WHERE key = 'offering';
  SELECT uri INTO ub_obs FROM lml_import.uribase WHERE key = 'observation';

  -- get the series id
  SELECT getseriesid INTO series_id FROM lml_import.getseriesid(
    ub_foi || publishstatcode
    , ub_obsprop || sensorcode
    , ub_sensor || publishstatcode || '/' || sensorcode)
  ;
  
  -- get the offering, codespace id
  SELECT offeringid INTO offer_id
    FROM sos.offering
    WHERE identifier = ub_offer || publishstatcode || '/' || sensorcode;
  SELECT codespaceid INTO codespace_id
    FROM sos.codespace
    WHERE codespace = 'http://www.opengis.net/def/nil/OGC/0/unknown';
  SELECT unitid INTO unit_id
    FROM sos.unit
    WHERE unit = munit;

  -- insert the observation
  SELECT nextval('sos.observationid_seq'::regclass) INTO obs_id;
  obs_uri := ub_obs || publishstatcode || '/' || sensorcode || '/' || mseriesid::text;
  INSERT INTO sos.observation(
            observationid, seriesid, phenomenontimestart, phenomenontimeend, 
            resulttime, identifier, codespaceid, deleted, unitid)
    VALUES (obs_id, series_id
            , timestart::timestamp with time zone AT TIME ZONE 'UTC'
            , timeend::timestamp with time zone AT TIME ZONE 'UTC'
            , result_time::timestamp with time zone AT TIME ZONE 'UTC'
            , obs_uri
            , codespace_id
            , 'F'
            , unit_id)
  ;

  -- insert the measured value
  INSERT INTO sos.numericvalue (observationid, value)
    VALUES(obs_id, mvalue);

  -- insert the link to the offering
  INSERT INTO sos.observationhasoffering (observationid, offeringid)
    VALUES(obs_id, offer_id);

  -- return observation identification
  RETURN obs_id;
END;
$$;


--
-- Name: lml_datetimeparse_tz(text, text); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION lml_datetimeparse_tz(date_time text, time_zone text) RETURNS timestamp with time zone
    LANGUAGE sql
    AS $$
SELECT (SUBSTR(date_time, 1, 8) || ' ' || SUBSTR(date_time, 9) || time_zone)::timestamp with time zone;
$$;


--
-- Name: lml_xmlfile_process(); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION lml_xmlfile_process() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (NEW.ts_processed is NULL OR NEW.ts_processed < NEW.ts_updated) THEN
    -- DELETE OLD STUFF
    DELETE FROM lml_import.measurements WHERE xmlfilename = NEW.xmlfilename;
    
    -- INSERT NEW (this is all LML stuff: LML names used)
    INSERT INTO lml_import.measurements (xmlfilename, station_id, sensorcode, m_value, begindatetime, enddatetime)
    with xp as
    (select
      NEW.xmlfilename
      , NEW.component
      , unnest(xpath('/ROWSET/ROW/STAT_NUMMER/text()', NEW.xmldata))::character varying (16) as stationcode
      , unnest(xpath('/ROWSET/ROW/MWAA_WAARDE/text()', NEW.xmldata))::text::float as meetwaarde
      , unnest(xpath('/ROWSET/ROW/MWAA_BEGINDATUMTIJD/text()', NEW.xmldata))::character varying (16) as begindatumtijd
      , unnest(xpath('/ROWSET/ROW/MWAA_EINDDATUMTIJD/text()', NEW.xmldata))::character varying (16) as einddatumtijd
    )
    -- Here translation to more generic names takes place, by inserting them in the measurements table.
    select
      xmlfilename
      , lml_import.getstationid(stationcode)
      , component
      , meetwaarde
      , lml_import.lml_datetimeparse_tz(begindatumtijd, 'CET') as begindatetime
      , lml_import.lml_datetimeparse_tz(einddatumtijd, 'CET') as enddatetime
    from xp
    ;
  NEW.ts_processed = now();
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: process_sensor_tpl(text, text, text, text, text); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION process_sensor_tpl(tplname text, publishstatcode text, sensorcode text, sensorinputcode text, sensoroutputcode text) RETURNS text
    LANGUAGE plpgsql
    AS $_$
DECLARE
  tpl text;
  stat record;
  ub_sensor text;
  ub_foi text;
  ub_obsprop text;
  ub_offer text;
BEGIN
  -- get the template
  SELECT contents INTO tpl FROM lml_import.templates WHERE templatename = tplname;
  -- get the record
  SELECT * INTO stat FROM lml_import.vw_statsensunit WHERE publishstationcode = publishstatcode;
  -- get the various uri-bases
  SELECT uri INTO ub_sensor FROM lml_import.uribase WHERE key = 'procedure';
  SELECT uri INTO ub_foi FROM lml_import.uribase WHERE key = 'featureofinterest';
  SELECT uri INTO ub_obsprop FROM lml_import.uribase WHERE key = 'observableproperty';
  SELECT uri INTO ub_offer FROM lml_import.uribase WHERE key = 'offering';
  
  -- replace/insert values
  -- procedure id
  tpl := replace(tpl, '$sensor.id$', ub_sensor || publishstatcode || '/' || sensorcode);
  tpl := replace(tpl, '$sensor.longname$', stat.namespace || ' (' || sensorcode || ') ' || trim(stat.name || ' ' || stat.municipality));
  tpl := replace(tpl, '$sensor.shortname$', stat.name || ' (' || sensorcode || ')');

  -- offering
  tpl := replace(tpl, '$sensor.offering.name$', 'Offering for: ' || stat.name || ' (' || sensorcode || ')');
  tpl := replace(tpl, '$sensor.offering.id$', ub_offer || publishstatcode || '/' || sensorcode);

  -- parentproc 
  tpl := replace(tpl, '$sensor.parent.id$', ub_sensor || sensorcode);

  -- feat of interest
  tpl := replace(tpl, '$sensor.featureofinterest.id$', ub_foi || publishstatcode);

  -- position
  tpl := replace(tpl, '$sensor.pos.gmlid$', stat.gmlid);
  tpl := replace(tpl, '$sensor.pos.easting$', st_x(st_transform(stat.geom, 4326))::text);
  tpl := replace(tpl, '$sensor.pos.northing$', st_y(st_transform(stat.geom, 4326))::text);
  tpl := replace(tpl, '$sensor.pos.altitudeunit$', stat.altitudeunit::text);
  tpl := replace(tpl, '$sensor.pos.altitude$', stat.altitude::text);

  -- input/output
  tpl := replace(tpl, '$sensor.input.name$', sensorinputcode);
  tpl := replace(tpl, '$sensor.observableproperty.input.id$', ub_obsprop || sensorinputcode);
  tpl := replace(tpl, '$sensor.output.name$', sensoroutputcode);
  tpl := replace(tpl, '$sensor.observableproperty.output.id$', ub_obsprop || sensorcode);
  
  -- unit
  tpl := replace(tpl, '$observation.unit$', stat.m_unit);

  -- show result (for debugging)
  -- RAISE NOTICE '%', tpl;

  -- return procedure id
  RETURN tpl;
END;
$_$;


--
-- Name: publish_sos(); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION publish_sos() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  stat record;
BEGIN
  -- call the insertobservation function, but before that look up publishstationcode and unit
  -- by searching in the view vw_statsenscode these can be lookup up, hopefully fast enough.

  -- Omit specific values (the typical nodata values)
  IF NEW.m_value < -900 THEN
    -- Insert into meetreeks, do not publish to sos.
    -- Alternative: RETURN NULL; that would skip it entirely.
    RETURN NEW;
  END IF;

  -- Get station, sensor, unit  
  SELECT publishstationcode, m_unit INTO stat
  FROM lml_import.vw_statsensunit s
  WHERE s.station_id = NEW.station_id
  AND s.sensorcode = NEW.sensorcode
  AND s.publish_sos = true;
  -- RAISE NOTICE '%', stat;
  
  -- Check for active. If no result, do not take action.
  IF stat IS NULL THEN
    RETURN NEW;
  ELSE
    SELECT insertobservation INTO NEW.sos_observationid
    FROM lml_import.insertobservation(
      NEW.id
      , stat.publishstationcode
      , NEW.sensorcode
      , NEW.m_value
      , stat.m_unit
      , NEW.begindatetime -- must be with time zone!
      , NEW.enddatetime
      , now()
    );
    RETURN NEW;
  END IF;
END;
$$;


--
-- Name: restoreobservation(bigint, bigint, text, text, double precision, text, timestamp with time zone, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION restoreobservation(obsid bigint, mseriesid bigint, publishstatcode text, sensorcode text, mvalue double precision, munit text, timestart timestamp with time zone, timeend timestamp with time zone, result_time timestamp with time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  -- uri bases
  ub_sensor text;
  ub_foi text;
  ub_obsprop text;
  ub_offer text;
  ub_obs text;

  -- ids
  offer_id bigint;
  unit_id bigint;
  series_id bigint;
  codespace_id bigint;

  -- uri ids
  obs_uri text;

BEGIN
  -- get the various uri-bases
  SELECT uri INTO ub_sensor FROM lml_import.uribase WHERE key = 'procedure';
  SELECT uri INTO ub_foi FROM lml_import.uribase WHERE key = 'featureofinterest';
  SELECT uri INTO ub_obsprop FROM lml_import.uribase WHERE key = 'observableproperty';
  SELECT uri INTO ub_offer FROM lml_import.uribase WHERE key = 'offering';
  SELECT uri INTO ub_obs FROM lml_import.uribase WHERE key = 'observation';

  -- get the series id
  SELECT getseriesid INTO series_id FROM lml_import.getseriesid(
    ub_foi || publishstatcode
    , ub_obsprop || sensorcode
    , ub_sensor || publishstatcode || '/' || sensorcode)
  ;
  
  -- get the offering, codespace id
  SELECT offeringid INTO offer_id
    FROM sos.offering
    WHERE identifier = ub_offer || publishstatcode || '/' || sensorcode;
  SELECT codespaceid INTO codespace_id
    FROM sos.codespace
    WHERE codespace = 'http://www.opengis.net/def/nil/OGC/0/unknown';
  SELECT unitid INTO unit_id
    FROM sos.unit
    WHERE unit = munit;

  -- insert the observation
  obs_uri := ub_obs || publishstatcode || '/' || sensorcode || '/' || mseriesid::text;
  INSERT INTO sos.observation(
            observationid, seriesid, phenomenontimestart, phenomenontimeend, 
            resulttime, identifier, codespaceid, deleted, unitid)
    VALUES (obsid, series_id
            , timestart::timestamp with time zone AT TIME ZONE 'UTC'
            , timeend::timestamp with time zone AT TIME ZONE 'UTC'
            , result_time::timestamp with time zone AT TIME ZONE 'UTC'
            , obs_uri
            , codespace_id
            , 'F'
            , unit_id)
  ;

  -- insert the measured value
  INSERT INTO sos.numericvalue (observationid, value)
    VALUES(obsid, mvalue);

  -- insert the link to the offering
  INSERT INTO sos.observationhasoffering (observationid, offeringid)
    VALUES(obsid, offer_id);

  -- return observation identification
  RETURN obsid;
END;
$$;


--
-- Name: unpublish_sos(); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION unpublish_sos() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Mark observations to delete
  UPDATE sos.observation
  SET deleted = 'T'
  WHERE observationid = OLD.sos_observationid;

  -- The next steps are introduced as a workaround for a bug in the SOS software,
  -- but can be left in place.
  IF (SELECT configvalue FROM lml_import.configuration WHERE key = 'sos.autoremove.deleted') = 'T' THEN
    DELETE FROM sos.numericvalue
    WHERE observationid IN (
      SELECT observationid
      FROM sos.observation
      WHERE deleted = 'T')
    ;
    DELETE FROM sos.observationhasoffering
    WHERE observationid IN (
      SELECT observationid
      FROM sos.observation
      WHERE deleted = 'T')
    ;
    DELETE FROM sos.observation
    WHERE deleted = 'T'
    ;
  END IF;
  -- end of workaround
  
  RETURN OLD;
END;
$$;


--
-- Name: updateseries(); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION updateseries() RETURNS boolean
    LANGUAGE sql
    AS $$
  UPDATE sos.series s
    SET firsttimestamp = u.firsttimestamp
      , lasttimestamp = u.lasttimestamp
      , firstnumericvalue = u.firstnumericvalue
      , lastnumericvalue = u.lastnumericvalue
    FROM (
      WITH mm AS
        (SELECT seriesid
            , min(o.phenomenontimeend) d_min, max(o.phenomenontimeend) d_max
          FROM sos.observation o
          JOIN sos.numericvalue n
            ON o.observationid = n.observationid
            WHERE o.deleted = 'F'
          GROUP BY o.seriesid)
      SELECT m1.seriesid, firsttimestamp, lasttimestamp
        , firstnumericvalue, lastnumericvalue
      FROM (
        SELECT mm.seriesid, obs.phenomenontimeend as firsttimestamp, value as firstnumericvalue
        FROM sos.observation obs
        JOIN mm
          ON obs.seriesid = mm.seriesid
            AND obs.phenomenontimeend = mm.d_min
            AND obs.deleted = 'F'
        JOIN sos.numericvalue v
          ON v.observationid = obs.observationid
      ) m1
      , (
        SELECT mm.seriesid, obs.phenomenontimeend as lasttimestamp, value as lastnumericvalue
        FROM sos.observation obs
        JOIN mm
          ON obs.seriesid = mm.seriesid
            AND obs.phenomenontimeend = mm.d_max
            AND obs.deleted = 'F'
        JOIN sos.numericvalue v
          ON v.observationid = obs.observationid
      ) m2
      WHERE m1.seriesid = m2.seriesid
    ) u
  WHERE u.seriesid = s.seriesid
  RETURNING true;
$$;


--
-- Name: xmlfile_insert(text, xml, text, timestamp with time zone); Type: FUNCTION; Schema: lml_import; Owner: -
--

CREATE FUNCTION xmlfile_insert(xml_filename text, xml_data xml, the_component text, xmlfile_timestamp timestamp with time zone) RETURNS integer
    LANGUAGE plpgsql
    AS $_$
DECLARE
  present boolean;
  datacheck text;
BEGIN
  -- always delete entry from download_status (safe, all in one transaction and this function
  -- has no return path without action)
  DELETE FROM lml_import.download_failures WHERE filename = xml_filename;
  
  -- check if already present, based on name
  SELECT EXISTS INTO present (SELECT 1 FROM lml_import.xml_files WHERE xmlfilename = xml_filename) p;
  IF (present = FALSE) THEN -- insert
    INSERT INTO lml_import.xml_files(
                xmlfilename, xmldata, xmldatachksum, component, ts_xmlfile, 
                ts_created)
        VALUES (xml_filename, xml_data, md5(xml_data::text), the_component, xmlfile_timestamp, now());
    RETURN 1;
  ELSE -- check/update
    SELECT xmldatachksum INTO datacheck FROM lml_import.xml_files WHERE xmlfilename = xml_filename;
    RAISE NOTICE 'Checksum %', datacheck;
    IF (datacheck = md5(xml_data::text)) THEN -- present, same contents, update checked
      RAISE NOTICE 'Checked %', xml_filename;
      UPDATE lml_import.xml_files SET ts_checked = now() 
        WHERE xmlfilename = xml_filename;
      RETURN 2;
    ELSE
      RAISE NOTICE 'Update %', xml_filename;
      UPDATE lml_import.xml_files SET xmldata = $2, xmldatachksum = md5($2::text)
          , ts_checked = now(), ts_updated = now()
        WHERE xmlfilename = xml_filename;
      RETURN 3;
    END IF;
  END IF;
END;
$_$;


SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: configuration; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE configuration (
    id integer NOT NULL,
    key text,
    configvalue text
);


--
-- Name: configuration_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE configuration_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: configuration_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE configuration_id_seq OWNED BY configuration.id;


--
-- Name: download_failures; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE download_failures (
    id bigint NOT NULL,
    filename character varying(128),
    status character varying(16),
    ts_created timestamp with time zone
);


--
-- Name: download_failures_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE download_failures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: download_failures_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE download_failures_id_seq OWNED BY download_failures.id;


--
-- Name: measurements; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE measurements (
    id bigint NOT NULL,
    xmlfilename character varying(128),
    station_id bigint,
    sensorcode text,
    m_value double precision,
    begindatetime timestamp with time zone,
    enddatetime timestamp with time zone,
    sos_observationid bigint
);


--
-- Name: measurements_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE measurements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: measurements_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE measurements_id_seq OWNED BY measurements.id;


--
-- Name: message_log; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE message_log (
    id bigint NOT NULL,
    msgtimestamp timestamp with time zone,
    operation text,
    filename text,
    msglevel text,
    msg text,
    ts_created timestamp with time zone
);


--
-- Name: message_log_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE message_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: message_log_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE message_log_id_seq OWNED BY message_log.id;


--
-- Name: sensors; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE sensors (
    id bigint NOT NULL,
    sensorcode character varying(16),
    description text,
    download boolean
);


--
-- Name: sensors_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE sensors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sensors_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE sensors_id_seq OWNED BY sensors.id;


--
-- Name: stations_eionet; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE stations_eionet (
    id bigint NOT NULL,
    gmlid text,
    localid text,
    namespace text,
    version text,
    natlstationcode text,
    name text,
    municipality text,
    eustationcode text,
    activitybegin text,
    activityend text,
    pos text,
    srsname text,
    altitude double precision,
    altitudeunit text,
    areaclassification text,
    belongsto text,
    geom public.geometry(PointZ,4326)
);


--
-- Name: stations_eionet_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE stations_eionet_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stations_eionet_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE stations_eionet_id_seq OWNED BY stations_eionet.id;


--
-- Name: statsensunit; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE statsensunit (
    id bigint NOT NULL,
    station_id bigint,
    sensor_id bigint,
    unit_id bigint,
    publish_sos boolean
);


--
-- Name: statsensunit_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE statsensunit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: statsensunit_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE statsensunit_id_seq OWNED BY statsensunit.id;


--
-- Name: templates; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE templates (
    id integer NOT NULL,
    templatename text,
    templatetype text,
    contents text
);


--
-- Name: templates_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: templates_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE templates_id_seq OWNED BY templates.id;


--
-- Name: units; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE units (
    id bigint NOT NULL,
    m_unit character varying(16)
);


--
-- Name: units_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE units_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: units_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE units_id_seq OWNED BY units.id;


--
-- Name: uribase; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE uribase (
    id bigint NOT NULL,
    key text,
    uri text
);


--
-- Name: uribase_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE uribase_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: uribase_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE uribase_id_seq OWNED BY uribase.id;


--
-- Name: xml_files; Type: TABLE; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE TABLE xml_files (
    id bigint NOT NULL,
    xmlfilename character varying(128),
    xmldata xml,
    xmldatachksum text,
    component character varying(8),
    ts_xmlfile timestamp with time zone,
    ts_created timestamp with time zone,
    ts_checked timestamp with time zone,
    ts_updated timestamp with time zone,
    ts_processed timestamp with time zone
);


--
-- Name: vw_download_failures; Type: VIEW; Schema: lml_import; Owner: -
--

CREATE VIEW vw_download_failures AS
    SELECT download_status.id, download_status.filename FROM download_failures download_status WHERE ((NOT ((download_status.filename)::text IN (SELECT xml_files.xmlfilename FROM xml_files))) AND ((download_status.status)::text = 'RETRY'::text));


--
-- Name: vw_stations; Type: VIEW; Schema: lml_import; Owner: -
--

CREATE VIEW vw_stations AS
    SELECT stations.id, stations.natlstationcode AS stationcode, stations.gmlid, stations.localid, stations.eustationcode AS publishstationcode, stations.namespace, stations.version, stations.name, stations.municipality, stations.activitybegin, stations.activityend, stations.srsname, stations.areaclassification, stations.belongsto, stations.altitude, stations.altitudeunit, stations.geom FROM stations_eionet stations;


--
-- Name: vw_statsensunit; Type: VIEW; Schema: lml_import; Owner: -
--

CREATE VIEW vw_statsensunit AS
    SELECT ssu.id, ssu.station_id, s.stationcode, s.gmlid, s.namespace, s.publishstationcode, s.name, s.municipality, s.areaclassification, ssu.sensor_id, r.sensorcode, ssu.unit_id, u.m_unit, ssu.publish_sos, s.activitybegin, s.activityend, s.geom, s.altitudeunit, s.altitude FROM (((statsensunit ssu JOIN vw_stations s ON ((s.id = ssu.station_id))) JOIN sensors r ON ((r.id = ssu.sensor_id))) JOIN units u ON ((u.id = ssu.unit_id)));


--
-- Name: vw_xmltoprocess; Type: VIEW; Schema: lml_import; Owner: -
--

CREATE VIEW vw_xmltoprocess AS
    SELECT xml_files.id, xml_files.xmlfilename FROM xml_files WHERE ((xml_files.ts_processed IS NULL) OR (xml_files.ts_updated > xml_files.ts_processed));


--
-- Name: xml_files_id_seq; Type: SEQUENCE; Schema: lml_import; Owner: -
--

CREATE SEQUENCE xml_files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: xml_files_id_seq; Type: SEQUENCE OWNED BY; Schema: lml_import; Owner: -
--

ALTER SEQUENCE xml_files_id_seq OWNED BY xml_files.id;


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY configuration ALTER COLUMN id SET DEFAULT nextval('configuration_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY download_failures ALTER COLUMN id SET DEFAULT nextval('download_failures_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY measurements ALTER COLUMN id SET DEFAULT nextval('measurements_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY message_log ALTER COLUMN id SET DEFAULT nextval('message_log_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY sensors ALTER COLUMN id SET DEFAULT nextval('sensors_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY stations_eionet ALTER COLUMN id SET DEFAULT nextval('stations_eionet_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY statsensunit ALTER COLUMN id SET DEFAULT nextval('statsensunit_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY templates ALTER COLUMN id SET DEFAULT nextval('templates_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY units ALTER COLUMN id SET DEFAULT nextval('units_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY uribase ALTER COLUMN id SET DEFAULT nextval('uribase_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: lml_import; Owner: -
--

ALTER TABLE ONLY xml_files ALTER COLUMN id SET DEFAULT nextval('xml_files_id_seq'::regclass);


--
-- Name: configuration_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY configuration
    ADD CONSTRAINT configuration_pkey PRIMARY KEY (id);


--
-- Name: download_failures_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY download_failures
    ADD CONSTRAINT download_failures_pkey PRIMARY KEY (id);


--
-- Name: eionet_stats_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY stations_eionet
    ADD CONSTRAINT eionet_stats_pkey PRIMARY KEY (id);


--
-- Name: measurements_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY measurements
    ADD CONSTRAINT measurements_pkey PRIMARY KEY (id);


--
-- Name: message_log_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY message_log
    ADD CONSTRAINT message_log_pkey PRIMARY KEY (id);


--
-- Name: sensors_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY sensors
    ADD CONSTRAINT sensors_pkey PRIMARY KEY (id);


--
-- Name: statsensunit_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY statsensunit
    ADD CONSTRAINT statsensunit_pkey PRIMARY KEY (id);


--
-- Name: templates_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY templates
    ADD CONSTRAINT templates_pkey PRIMARY KEY (id);


--
-- Name: units_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY units
    ADD CONSTRAINT units_pkey PRIMARY KEY (id);


--
-- Name: uribase_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY uribase
    ADD CONSTRAINT uribase_pkey PRIMARY KEY (id);


--
-- Name: xml_files_pkey; Type: CONSTRAINT; Schema: lml_import; Owner: -; Tablespace: 
--

ALTER TABLE ONLY xml_files
    ADD CONSTRAINT xml_files_pkey PRIMARY KEY (id);


--
-- Name: eionet_stats_geom_idx; Type: INDEX; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE INDEX eionet_stats_geom_idx ON stations_eionet USING gist (geom);


--
-- Name: stations_natlstationcode_idx; Type: INDEX; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE INDEX stations_natlstationcode_idx ON stations_eionet USING btree (natlstationcode);


--
-- Name: xml_files_ts_xmlfile_idx; Type: INDEX; Schema: lml_import; Owner: -; Tablespace: 
--

CREATE INDEX xml_files_ts_xmlfile_idx ON xml_files USING btree (ts_xmlfile);


--
-- Name: delete_unpublish_sos; Type: TRIGGER; Schema: lml_import; Owner: -
--

CREATE TRIGGER delete_unpublish_sos AFTER DELETE ON measurements FOR EACH ROW EXECUTE PROCEDURE unpublish_sos();


--
-- Name: download_failures_insertprotect; Type: TRIGGER; Schema: lml_import; Owner: -
--

CREATE TRIGGER download_failures_insertprotect BEFORE INSERT ON download_failures FOR EACH ROW EXECUTE PROCEDURE download_failures_insert();


--
-- Name: insert_publish_sos; Type: TRIGGER; Schema: lml_import; Owner: -
--

CREATE TRIGGER insert_publish_sos BEFORE INSERT ON measurements FOR EACH ROW EXECUTE PROCEDURE publish_sos();


--
-- Name: lml_xmlfile_cachedata; Type: TRIGGER; Schema: lml_import; Owner: -
--

CREATE TRIGGER lml_xmlfile_cachedata BEFORE INSERT OR UPDATE ON xml_files FOR EACH ROW EXECUTE PROCEDURE lml_xmlfile_process();


--
-- PostgreSQL database dump complete
--

