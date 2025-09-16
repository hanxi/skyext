-- Code generated from tools/gen_roleagent_modules.lua
-- DO NOT EDIT!

local schema = require "orm.schema"
local sproto_api = require "sproto_api"
local bag_request = require "modules.bag.request"
local bag = require "modules.bag"
local role_request = require "modules.role.request"
local mail_request = require "modules.mail.request"
local mail = require "modules.mail"

local M = {}
function M.init(client)
    sproto_api.register_module("bag", client, bag_request)
    sproto_api.register_module("role", client, role_request)
    sproto_api.register_module("mail", client, mail_request)
end

function M.load(role_obj, role_data)
    if role_data.modules == nil then
        role_data.modules = {}
    end

    role_obj.modules = {}

    if role_data.modules.bag == nil then
        role_data.modules.bag = {}
    end
    role_obj.modules.bag = bag.new(role_obj, role_data.modules.bag)

    if role_data.modules.mail == nil then
        role_data.modules.mail = {}
    end
    role_obj.modules.mail = mail.new(role_obj, role_data.modules.mail)
end
return M
