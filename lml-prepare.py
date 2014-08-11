#!/usr/bin/env python
#==============================================================================
#title           :lml-prepare.py
#description     :Prepares a SOS database to receive observation data.
#                 Inserts sensor (procedure), resulttemplate, featureofinterest,
#                 based on station,sensor,unit configuration.
#                 Uses the SOS server json and kvp api (config in database),
#                 database configuration in 'sos_config.py'.
#author          :Wouter Boasson
#date            :20140731
#version         :1.1
#usage           :python lml-prepare.py
#notes           :Running the script is pretty harmless, the SOS server with
#                 database constraints prevent duplicates in the database.
#python_version  :2.7.x
#==============================================================================

import os, sys, time
import urllib, urllib2, socket
import json
import uuid
import psycopg2, psycopg2.extras
from datetime import datetime
from datetime import timedelta
import xml.etree.ElementTree as ET
from sos_config import *

print """Prepare SOS-service for LML-data.
(c) Wouter Boasson, 2014
"""

VERBOSE = False
DRYRUN = False
#VERBOSE = True
#DRYRUN = True

# Global variables + example
# The actual values will be retrieved from the database (table: <schema>.configuration)
#SOSSERVER = "http://your.sosserver.eu/sos/"
#SOSJSON = "sos/json"
#SOSKVP = "sos/kvp?"
#AUTHTOKEN = "Your auth token"
#HTTPTIMEOUT = 5 (in seconds)
#RETRYWAIT = 0.05 (in seconds)

now = datetime.now()

# Read configuration keys from database
def GetConfigFromDb(pgcur, key):
  sql = "SELECT configvalue FROM configuration WHERE key = %s;"
  pgcur.execute(sql, (key, ))
  return pgcur.fetchone()[0]

# Http GET request to the SOS KVP service endpoint
# (needed to delete temporary observations)
def HttpGet(myrequest):
  fullpath = SOSKVP + myrequest
  socket.timeout(HTTPTIMEOUT)
  headers = {"Authorization": AUTHTOKEN}
  req = urllib2.Request(SOSSERVER + fullpath, None, headers)
  try:
    response = urllib2.urlopen(req)
  except urllib2.HTTPError as e:
    print '  the server couldn\'t fulfill the request.'
    print '  error code:', e.code, fullpath
    return "ERROR:HTTP " + str(e.code) + " " + SOSSERVER + fullpath
  except urllib2.URLError as e:
    print '  we failed to reach a server.'
    print '  reason:', e.reason, fullpath
    return "ERROR:URL " + str(e.reason) + " " + SOSSERVER + fullpath
  except socket.timeout, e:
    print '  server timeout', fullpath
    return "ERROR:CONNECTION " + str(e) + " " + SOSSERVER + fullpath
  else:
    result = response.read()
    return result

# POST request to the SOS JSON service
# (in use for inserting sensor, resulttemplate, featureofinterest, observation)
def HttpPostData(postdata):
  socket.timeout(HTTPTIMEOUT)
  try:
    headers = {"Content-type": "application/json", "Accept": "application/json", "Authorization": AUTHTOKEN}
    req = urllib2.Request(SOSSERVER + SOSJSON, postdata, headers)
    response = urllib2.urlopen(req)
    return response.read()
  except urllib2.HTTPError as e:
    print '  error: ' + str(e.code)
    return "ERROR:HTTP " + str(e.code)

# Insert error message in database
# (logging)
def LogMsg(pgcur, operation, filename, msg):
  msglevel = msg[:msg.find(":")]
  sql = "INSERT INTO message_log(msgtimestamp, operation, filename, msglevel, msg, ts_created) values (clock_timestamp(), %s, %s, %s, %s, now());"
  pgcur.execute(sql, (operation, filename, msglevel, msg[msg.find(":") + 1:]))

# Get a template
# (templates for sensor, resulttemplate and featureofinterest and observation are
# stored in the database)
def GetTemplate(pgcur, tpltype, template):
  sql = "SELECT contents FROM templates WHERE templatetype = %s AND templatename = %s"
  pgcur.execute(sql, (tpltype, template))
  return str(pgcur.fetchone()[0]).replace("\r", "\n") # just in case, when created on a mac

# Get the SensorML (produced by a database function)
# (SensorMl is also constructed from a template, but that's done in the database, easier
# because a lot of data have to be pulled together)
def GetSensorMl(pgcur, template, publishstatcode, component, inputname, outputname):
  sql = "select process_sensor_tpl from " + SCHEMA + ".process_sensor_tpl(%s, %s, %s, %s, %s);"
  pgcur.execute(sql, (template, publishstatcode, component, inputname, outputname))
  return str(pgcur.fetchone()[0]).replace("\r", "\n") # just in case, when created on a mac

# ###################################################################################################################
# 'Main'
# Open global database connection
conn_string = "host='"+DBHOST+"' port='"+DBPORT+"' dbname='"+DATABASE+"' user='"+DBUSER+"' password='" + DBPWD + "'"
print "Connecting to database..."
conn = psycopg2.connect(conn_string)
cursor = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
cursor.execute("SET search_path = " + SCHEMA + ",public;")
print "Connected!\n"

# Get configuration (see top of file for examples)
SOSSERVER = GetConfigFromDb(cursor, 'sos.server.httpaddress')
SOSJSON = GetConfigFromDb(cursor, 'sos.server.api.json')
SOSKVP = GetConfigFromDb(cursor, 'sos.server.api.kvp')
AUTHTOKEN = GetConfigFromDb(cursor, 'sos.server.authtoken')
HTTPTIMEOUT = float(GetConfigFromDb(cursor, 'http.timeout'))
RETRYWAIT = float(GetConfigFromDb(cursor, 'http.retrywait'))

# Set XML namespaces
nsp = {'sml': 'http://www.opengis.net/sensorML/1.0.1'
  , 'swe': 'http://www.opengis.net/swe/1.0.1'}

# Loop through the active and to publish sensors
sql = "SELECT * FROM vw_statsensunit WHERE publish_sos = true AND activityend is null;"
cursor.execute(sql)
result = cursor.fetchall()
tempIds = [] # list of temporary ids that need to be removed (observations are created to get the units inserted)
print 'Creating sensors and features of interest (by inserting temporary observations)'
c = 0
for r in result:
  print r['publishstationcode'] + ' (' + r['name'] + '): ' + r['sensorcode']
  # Get the SensorML, and initiate XML parser
  sensorml = GetSensorMl(cursor, 'SensorML.basic', r['publishstationcode'], r['sensorcode'], 'air', r['sensorcode'] + '_value')
  try:
    root = ET.fromstring(sensorml)
  except:
    print sensorml
    sys.exit()

  # ObservableProperty read from the SensorML (so they always match :-) )
  observableproperty = root.findall(".//sml:outputs/sml:OutputList/sml:output/swe:Category", nsp)[0].attrib['definition'] 

  # Offering
  offering = root.findall(".//*[@definition='urn:ogc:def:identifier:OGC:offeringID']/swe:value", nsp)[0].text
  sensorid = root.findall(".//*[@definition='urn:ogc:def:identifier:OGC:1.0:uniqueID']/sml:value", nsp)[0].text 

  # FeatureOfInterest
  foiId = root.findall(".//*/sml:capabilities[@name='featuresOfInterest']/swe:SimpleDataRecord/swe:field[@name='featureOfInterestID']/swe:Text/swe:value", nsp)[0].text
  foiName = r["name"]
  if r["municipality"] != '':
    foiName = foiName + ", " + r['municipality']
  foiSampledfeat = root.findall(".//sml:inputs/sml:InputList/sml:input/swe:ObservableProperty", nsp)[0].attrib['definition']
  # X, Y, Z
  posY = root.findall(".//*/sml:position[@name='sensorPosition']/swe:Position/swe:location/swe:Vector/swe:coordinate[@name='northing']/swe:Quantity/swe:value", nsp)[0].text
  posX = root.findall(".//*/sml:position[@name='sensorPosition']/swe:Position/swe:location/swe:Vector/swe:coordinate[@name='easting']/swe:Quantity/swe:value", nsp)[0].text
  posZ = root.findall(".//*/sml:position[@name='sensorPosition']/swe:Position/swe:location/swe:Vector/swe:coordinate[@name='altitude']/swe:Quantity/swe:value", nsp)[0].text

  # Observation
  unit = r["m_unit"] # from unit table, everything else can be default, will be thrown away

  # Process the insertsensor template
  insertsensor = GetTemplate(cursor, "JSON", "InsertSensor.SamplingPoint.Measurement")
  insertsensor = insertsensor.replace("$procedure.sensorml$", sensorml.replace("\"","\\\""))
  insertsensor = insertsensor.replace("$sensor.observableproperty.output.id$", observableproperty)
  insertsensor = insertsensor.replace("\r","").replace("\n","")
  if VERBOSE:
    print insertsensor
  if not DRYRUN:
    j = HttpPostData(insertsensor)
    try:
      print '  => ' + json.loads(j)['request'] + ' ' + json.loads(j)['assignedProcedure']
    except:
      print '  => error, probably already present'

  # Process the insertresulttemplate template
  insertresulttpl = GetTemplate(cursor, "JSON", "InsertResultTemplate")
  insertresulttpl = insertresulttpl.replace('$sensor.id$', sensorid)
  insertresulttpl = insertresulttpl.replace('$sensor.resulttemplate.id$', sensorid + '/template/basic')
  insertresulttpl = insertresulttpl.replace('$sensor.offering$', offering)
  insertresulttpl = insertresulttpl.replace('$sensor.observableproperty.output.id$', observableproperty)
  insertresulttpl = insertresulttpl.replace('$sensor.featureofinterest.id$', foiId)
  insertresulttpl = insertresulttpl.replace("$sensor.featureofinterest.name$", foiName)
  insertresulttpl = insertresulttpl.replace('$sensor.output.name$', 'value')
  insertresulttpl = insertresulttpl.replace('$sensor.observableproperty.output.id$', observableproperty)
  insertresulttpl = insertresulttpl.replace("$sensor.pos.northing$", posY)
  insertresulttpl = insertresulttpl.replace("$sensor.pos.easting$", posX)
  insertresulttpl = insertresulttpl.replace("$sensor.pos.altitude$", posZ)
  insertresulttpl = insertresulttpl.replace("$observation.unit$", unit)
  if VERBOSE:
    print insertresulttpl
  if not DRYRUN:
    j = HttpPostData(insertresulttpl)
    try: 
      print '  => ' + json.loads(j)['request'] + ' ' + json.loads(j)['acceptedTemplate'] 
    except:
      print '  => error, probably already present'
  
  # Process the insertobservation template
  tempid = sensorid + '/' + str(uuid.uuid4())
  tempIds.append(tempid)
  insertobservation = GetTemplate(cursor, 'JSON', 'InsertObservation')
  insertobservation = insertobservation.replace("$sensor.offering.id$", offering)
  insertobservation = insertobservation.replace("$sensor.observation.id$", tempid)
  insertobservation = insertobservation.replace("$sensor.id$", sensorid)
  insertobservation = insertobservation.replace("$sensor.observableproperty.output.id$", observableproperty)
  insertobservation = insertobservation.replace("$sensor.featureofinterest.id$", foiId)
  insertobservation = insertobservation.replace("$sensor.featureofinterest.name$", foiName)
  insertobservation = insertobservation.replace("$sensor.featureofinterest.sampled$", foiSampledfeat)
  insertobservation = insertobservation.replace("$sensor.pos.northing$", posY)
  insertobservation = insertobservation.replace("$sensor.pos.easting$", posX)
  insertobservation = insertobservation.replace("$sensor.pos.altitude$", posZ)
  insertobservation = insertobservation.replace("$observation.time$", "2000-01-01T00:00:00+00:00")
  insertobservation = insertobservation.replace("$result.time$", "2000-01-01T00:00:00+00:00")
  insertobservation = insertobservation.replace("$observation.unit$", unit)
  insertobservation = insertobservation.replace("$observation.value$", "0")
  if VERBOSE:
    print insertobservation
  if not DRYRUN:
    j = HttpPostData(insertobservation)
    try: 
      print '  => ' + json.loads(j)['request'] + ' ' + sensorid
    except:
      print '  => error, probably already present'

  c += 1

print "Deleting temporary observations (" + str(c) + ")"
n = 0
for t in tempIds:
  deleterequest = "service=SOS&version=2.0.0&request=DeleteObservation&observation=" + urllib.quote_plus(t)
  if not DRYRUN:
    HttpGet(deleterequest)
  if VERBOSE:
    print deleterequest
  if n >= 5:
    sys.stderr.write(".")
    n = 0
  n += 1

print "Done."
print ""
print "Note: in order to fully remove the temporary observations, clean up"
print "'Deleted observations' using the SOS Admin interface."

conn.rollback() # Whatever happened, we do not want to write to the database.
conn.close()
# The end

