local jwt = require "jwt"
local log = require "log"


-- HS256
local token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6Ind3dy5iZWpzb24uY29tIiwic3ViIjoiZGVtbyIsImlhdCI6MTc1OTkzMDg5MCwibmJmIjoxNzU5OTMwODkwLCJleHAiOjE3NjAwMTcyOTB9.K-k4Rbw_rmfUubjWokBXWQyExsGMM0BiWj1yIdmnnTg"
local secret = "bejson858364"
local ret,msg = jwt.verify(token, secret)
if not ret then
    error(msg)
end
log.info("jwt hs256 ok", "ret", ret)

-- HS512
local token = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6Ind3dy5iZWpzb24uY29tIiwic3ViIjoiZGVtbyIsImlhdCI6MTc1OTkzMDg5MCwibmJmIjoxNzU5OTMwODkwLCJleHAiOjE3NjAwMTcyOTB9.XFnqU9IKIVEyL0em5nCLwf5C-FYNEEb1JTNz9WIHzVNz1p9QgkH0aY3FSoe_lLYv4gPSrDngph5CVvPuQ2SHbA"
local secret = "bejson858364"
local ret,msg = jwt.verify(token, secret)
if not ret then
    error(msg)
end
log.info("jwt hs512 ok", "ret", ret)

