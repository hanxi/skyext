local errcode = require "skyext.errcode"

errcode.ROLE_NOT_EXIST = 100
errcode.ROLE_TOO_MANY = 101
errcode.TOKEN_ERROR = 102
errcode.PROTO_CHECKSUM = 103
errcode.SERVER_NOT_EXIST = 104

return errcode
