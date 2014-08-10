#!/usr/bin/env python
#==============================================================================
#title           :lml-retrieve.py
#description     :Downloads measurements from an http server (targets RIVM LML
#                 format).
#                 Inserts files into the SOS database, in the import schema.
#                 It can really be any (text) file, the database keeps track
#                 of changes and should handle the content.
#author          :Wouter Boasson
#date            :20140731
#version         :1.0
#usage           :python lml-retrieve.py OR lml-retrieve.py [hours] [hours]
#notes           :Loading data multiple times is harmless when used against
#                 the lml_import tables and routines (in the database).
#python_version  :2.7.x
#==============================================================================

# Timestamps ts_* in datatables: transaction time (now()), in order to keep data and logs together.
# Message log timestamp: real time (clock time)

import os, sys, time
import urllib2, socket
import psycopg2
from datetime import datetime
from datetime import timedelta
from sos_config import *

print """Retrieve and process LML xml export for SOS
(c) Wouter Boasson, 2014
"""

if len(sys.argv) == 2  and sys.argv[1] == 'help':
  print """Usage: lml-retrieve {help} | {[timeframe] [retry-timeframe]}
  No options:      Uses defaults from database
  help:            This help text.
  timeframe:       Number of hours back from now, to retrieve data for.
                   Downloads may overlap with previous downloads, retrieved
                   data will be checked for differences (not imported multiple
                   times, only updated). Must be combined with retry-timeframe.
  retry-timeframe: Number of hours back from now, to perform retries for
                   previously failed downloads (only logged failures).
                   The webserver will be queried a little slower, and a more
                   forgiving time out value is set (+10 sec).
                   Setting this to 0 effectively disables any retries.
                   Must be combined with timeframe.
"""
  sys.exit()

# Global variables with examples.
# The actual configuration is in the database (table: <schema>.configuration).
#LMLSERVER = "http://my.hostname.somewhere"
#SOSXML = "/sos/"
#HTTPTIMEOUT = 5
#RETRYWAIT = 0.05
#HTTPPROXY = "http://my.proxy.server:port"

# Get the sensors to download
def GetSensors(pgcur):
  sensors = []
  sql = "SELECT sensorcode FROM sensors WHERE download = true;"
  pgcur.execute(sql)
  result = cursor.fetchall()
  for r in result:
    sensors.append(r[0])
  return sensors

# Read configuration keys from database
def GetConfigFromDb(pgcur, key):
  sql = "SELECT configvalue FROM configuration WHERE key = %s;"
  pgcur.execute(sql, (key, ))
  return pgcur.fetchone()[0]

# Retrieve the files, via http
def HttpGetFile(myfile, mytimeout):
  fullpath = SOSXML + myfile
  socket.timeout(HTTPTIMEOUT)
  req = urllib2.Request(LMLSERVER + fullpath)
  try:
    response = urllib2.urlopen(req, timeout=mytimeout)
  except urllib2.HTTPError as e:
    print '  the server couldn\'t fulfill the request.'
    print '  error code:', e.code, fullpath
    return "ERROR:HTTP " + str(e.code) + " " + LMLSERVER + fullpath
  except urllib2.URLError as e:
    print '  we failed to reach a server.'
    print '  reason:', e.reason, fullpath
    return "ERROR:URL " + str(e.reason) + " " + LMLSERVER + fullpath
  except socket.timeout, e:
    print '  server timeout', fullpath
    return "ERROR:CONNECTION " + str(e) + " " + LMLSERVER + fullpath
  else:
    result = response.read()
    return result

# Insert file in database
def StoreXml(pgcur, filename, xmldata, component, filetime):
  sql = "SELECT xmlfile_insert(%s, %s, %s, %s);"
  pgcur.execute(sql, (filename, xmldata, component, filetime))

# Insert error message in database
def LogMsg(pgcur, operation, filename, msg):
  msglevel = msg[:msg.find(":")]
  sql = "INSERT INTO message_log(msgtimestamp, operation, filename, msglevel, msg, ts_created) values (clock_timestamp(), %s, %s, %s, %s, now());"
  pgcur.execute(sql, (operation, filename, msglevel, msg[msg.find(":") + 1:]))

# Insert filename for retry
def StoreDownloadFailure(pgcur, filename, status):
  sql = "INSERT INTO download_failures (filename, status, ts_created) values (%s, %s, now());"
  cursor.execute(sql, (filename, status))

# Get list of files for retry
def GetFailedDownloads(hours):
  files = []
  sql = "SELECT filename FROM download_failures WHERE (now() - ts_created) < interval '%s hours';"
  cursor.execute(sql, (hours, ))
  result = cursor.fetchall()
  for r in result:
    files.append(r[0])
  return files

# Download and insert a given list of files
def DownloadInsertFiles(files, mytimeout, sleep):
  for myFile in files:
    stofje = myFile.upper().split("-")[1].replace('.XML', '')
    myTime = datetime.strptime(myFile.split("-")[0], "%Y%m%d%H")
    print "Retrieving: " + myFile + " (" + stofje + " " + myTime.strftime("%Y%m%d %H:00:00") + ")"
    data = HttpGetFile(myFile, mytimeout)
    if data[0:6] == "ERROR:":
      #print data[6:]
      # Log this (server, filename, timestamp, error code)
      LogMsg(cursor, "HTTPDownload", myFile, str(data))
      StoreDownloadFailure(cursor, myFile, "RETRY")
    else:
      # Stuff it into the database, the database will handle most of the processing
      if data == "":
        print "NoData"
        LogMsg(cursor, "HTTPDownload", myFile, "ERROR:NoData")
        StoreDownloadFailure(cursor, myFile, "RETRY")
      else:
        StoreXml(cursor, myFile, data, stofje, myTime.strftime("%Y%m%d %H:00:00+01"))
    time.sleep(sleep)

# Update the series table with min/max values
def UpdateSeries(pgcur):
  sql = "SELECT updateseries FROM updateseries();"
  cursor.execute(sql)
  return cursor.fetchone()[0]

# Open global database connection
conn_string = "host='"+DBHOST+"' port='"+DBPORT+"' dbname='"+DATABASE+"' user='"+DBUSER+"' password='" + DBPWD + "'"
print "Connecting to database..."
conn = psycopg2.connect(conn_string)
cursor = conn.cursor()
cursor.execute("SET search_path = " + SCHEMA + ",public;")
print "Connected!\n"

# Get configuration (see top of script for examples)
LMLSERVER = GetConfigFromDb(cursor, 'lml.server.httpaddress')
SOSXML = GetConfigFromDb(cursor, 'lml.server.directory')
HTTPTIMEOUT = float(GetConfigFromDb(cursor, 'http.timeout'))
RETRYWAIT = float(GetConfigFromDb(cursor, 'http.retrywait'))
HTTPPROXY = GetConfigFromDb(cursor, 'http.proxy')

# Set the proxy
if HTTPPROXY != None:
  os.environ['http_proxy'] = HTTPPROXY

# timeframes from server, or commandline
if len(sys.argv) == 3:
  timeframe = int(sys.argv[1]) # hours back from now, regular download
  retrytimeframe = int(sys.argv[2]) # hours back from now, retries for failed downloads
else:
  timeframe = int(GetConfigFromDb(cursor, 'lml.retrieve.timeframe'))
  retrytimeframe = int(GetConfigFromDb(cursor, 'lml.retrieve.retrytimeframe'))

now = datetime.now()

# Build list of files to download, from available configured sensors.
files = []
LogMsg(cursor, "HTTPDownload", "*", "INFO:Start of http downloads.")
for s in GetSensors(cursor):
  for i in range(timeframe):
    myTime = now - timedelta(hours = i)
    myFile = myTime.strftime("%Y%m%d%H") + "-" + s + ".xml"
    files.append(myFile)
DownloadInsertFiles(files, HTTPTIMEOUT, 0.001)
LogMsg(cursor, "HTTPDownload", "*", "INFO:End of http downloads.")
conn.commit()

# Get the download failures and retry, being a bit more forgiving to the webserver
files = GetFailedDownloads(retrytimeframe)
LogMsg(cursor, "HTTPDownload", "*", "INFO:Start of retrying failed http downloads.")
DownloadInsertFiles(files, HTTPTIMEOUT + 10, RETRYWAIT)
LogMsg(cursor, "HTTPDownload", "*", "INFO:End of retrying failed http downloads.")
conn.commit()

# Finally, udpate the series table
if UpdateSeries(cursor):
  print "Updated metadata successfully."

conn.commit()
conn.close()
# The end
