require("ingress_rbac_logging")

local _ = match._
local contains = function(substring) return match.matches(substring, nil, true) end
local function formatLog(method, path, source_ip, client_name, protocol, request_id, status_code, trusted_client, allowed_client, rbac_action, authority, lua_authority)
    return "\nINCOMING_PERMISSIONS { \"method\": \""..method..
        "\", \"path\": \""..path..
        "\", \"clientIp\": \""..source_ip..
        "\", \"clientName\": \""..escape(client_name)..
        "\", \"trustedClient\": "..tostring(trusted_client)..
        ", \"authority\": \""..escape(authority)..
        "\", \"luaDestinationAuthority\": \""..escape(lua_authority)..
        "\", \"clientAllowedToAllEndpoints\": "..tostring(allowed_client)..
        ", \"protocol\": \""..protocol..
        "\", \"requestId\": \""..escape(request_id)..
        "\", \"statusCode\": "..status_code..
        ", \"rbacAction\": \""..rbac_action.."\" }"
end

local function handlerMock(headers, dynamic_metadata, https, filter_metadata)
    local metadata_mock = mock({
        set = function() end,
        get = function(_, key) return dynamic_metadata[key] end
    })
    local log_info_mock = spy(function() end)
    return {
        headers = function() return {
            get = function(_, key)
                assert.is.not_nil(key, "headers:get() called with nil argument")
                return headers[key]
            end,
            add = function(_, key, value) headers[key] = value end
        }
        end,
        streamInfo = function() return {
            dynamicMetadata = function() return metadata_mock end,
        }
        end,
        connection = function() return {
            ssl = function() return https or nil end
        }
        end,
        logInfo = log_info_mock,
        metadata = function() return {
            get = function(_, key) return filter_metadata[key] end
        }
        end
    }
end

describe("json escape string:", function()
    local chars_to_escape = {
        ["\\"] = "\\\\",
        ["\""] = "\\\"",
        ["\b"] = "\\b",
        ["\f"] = "\\f",
        ["\n"] = "\\n",
        ["\r"] = "\\r",
        ["\t"] = "\\t",
        ['some \t text'] = 'some \\t text',
        ['multiple \" escaped \t text'] = 'multiple \\" escaped \\t text',
        ['/multiple \" escaped \t text/'] = '/multiple \\" escaped \\t text/',
        ['no escape here'] = 'no escape here',
        ["{\"hello\": \"world\"}"] = '{\\"hello\\": \\"world\\"}',
    }

    for given, expected in pairs(chars_to_escape) do
        it("should escape '"..given.."' with backslashes", function()
            -- when
            local escaped = escape(given)

            assert.equals(expected, escaped)
        end)
    end
end)

describe("envoy_on_request:", function()
    it("should set dynamic metadata", function()
        -- given
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
            ['x-service-name'] = 'lorem-service',
            ['x-forwarded-for'] = "127.0.4.3",
            [':authority'] = "authority",
            ['x-lua-destination-authority'] = "lua_authority"
        }
        local filter_metadata = {
            ['client_identity_headers'] = { 'x-service-name' }
        }

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.path", "/path")
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.method", "GET")
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.client_name", "lorem-service")
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.xff_header", "127.0.4.3")
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.authority", "authority")
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.lua_destination_authority", "lua_authority")
    end)

    it("should set dynamic metadata for request id", function()
        -- given
        local headers = {
            ['x-request-id'] = '123-456-789',
        }
        local filter_metadata = {
            ['request_id_headers'] = { 'x-request-id' }
        }

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.request_id", "123-456-789")
    end)

    it("should set allowed_client for defined client", function()
        -- given
        local headers = {
            ['x-service-name'] = 'allowed_client'
        }
        local filter_metadata = {
            ['client_identity_headers'] = { 'x-service-name' },
            ['clients_allowed_to_all_endpoints'] = { 'allowed_client' }
        }

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.allowed_client", true)
    end)

    it("should set allowed_client to false for unknown client", function()
        -- given
        local headers = {
            ['x-service-name'] = 'not_allowed_client'
        }
        local filter_metadata = {
            ['client_identity_headers'] = { 'x-service-name' },
            ['clients_allowed_to_all_endpoints'] = { 'allowed_client' }
        }

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.allowed_client", false)
    end)

    it("should set client_name from x-client-name-trusted header", function()
        -- given
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
            ['x-service-name'] = 'lorem-service',
            ['x-client-name-trusted'] = 'service-first,service-second'
        }
        local filter_metadata = {
            ['client_identity_headers'] = { "x-service-name" },
            ['trusted_client_identity_header'] = "x-client-name-trusted"
        }
        local handle = handlerMock(headers, {}, true, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.client_name", 'service-first,service-second')

    end)

    it("should add not trusted to client_name if ssl available and name was not from certificate", function()
        -- given
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
            ['x-service-name'] = 'lorem-service',
        }
        local filter_metadata = {
            ['client_identity_headers'] = { "x-service-name" },
            ['trusted_client_identity_header'] = "x-client-name-trusted"
        }

        local handle = handlerMock(headers, {}, true, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.client_name", 'lorem-service (not trusted)')
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.trusted_client", false)

    end)

    it("should set client_name metadata using data from configured headers", function()
        -- given
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
            ['x-service-name'] = 'lorem-service',
            ['x-forwarded-for'] = "127.0.4.3"
        }
        local filter_metadata = {
            ['client_identity_headers'] = { "x-service-name", "x-forwarded-for" }
        }

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.client_name", "lorem-service")
    end)

    it("should set client_name metadata using second configured header when first one is missing", function()
        -- given
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
            ['x-forwarded-for'] = "127.0.4.3"
        }
        local filter_metadata = {
            ['client_identity_headers'] = { "x-service-name", "x-forwarded-for" }
        }

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.client_name", "127.0.4.3")
    end)

    it("should set empty client_name when there are empty client_identity_headers configured", function()
        -- given
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
            ['x-forwarded-for'] = "127.0.4.3"
        }
        local filter_metadata = {
            ['client_identity_headers'] = {}
        }

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.client_name", "")
    end)

    it("should set empty client_name when there are no client_identity_headers configured", function()
        -- given
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
            ['x-forwarded-for'] = "127.0.4.3"
        }
        local filter_metadata = {}

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.client_name", "")
    end)

    it("should set empty client_name when there are no headers matching client_identity_headers", function()
        -- given
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
            ['x-forwarded-for'] = "127.0.4.3"
        }
        local filter_metadata = {
            ['client_identity_headers'] = { "x-service-name", "x-via-ip" }
        }

        local handle = handlerMock(headers, {}, nil, filter_metadata)
        local metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.client_name", "")
    end)

    it("should survive lack of trusted_client_identity_header metadata", function ()
        -- given
        local empty_metadata = {}
        local headers = {
            [':path'] = '/path',
            [':method'] = 'GET',
        }
        local handle = handlerMock(headers, {}, nil, empty_metadata)
        local dynamic_metadata = handle:streamInfo():dynamicMetadata()

        -- when
        envoy_on_request(handle)

        -- then
        assert.spy(dynamic_metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.path", "/path")
        assert.spy(dynamic_metadata.set).was_called_with(_, "envoy.filters.http.lua", "request.info.method", "GET")
    end)
end)

describe("envoy_on_response:", function()
    local headers
    local metadata
    local ssl

    before_each(function ()
        headers = {
            [':status'] = '403'
        }
        metadata = {
            ['envoy.filters.http.rbac'] = {
                ['shadow_engine_result'] = 'denied'
            },
            ['envoy.filters.http.lua'] = {
                ['service_name'] = "service",
                ['request.info.client_name'] = 'service-first',
                ['request.info.path'] = '/path?query=val',
                ['request.info.method'] = 'POST',
                ['request.info.xff_header'] = '127.1.1.3',
                ['request.info.authority'] = 'authority',
                ['request.info.lua_destination_authority'] = 'lua_authority'
            }
        }
        ssl = true
    end)

    describe("should log unauthorized requests:", function ()

        it("https request", function ()
            -- given
            local handle = handlerMock(headers, metadata, ssl)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "POST",
                "/path?query=val",
                "127.1.1.3",
                "service-first",
                "https",
                "",
                "403",
                false,
                false,
                "denied",
                "authority",
                "lua_authority"
            ))
            assert.spy(handle.logInfo).was_called(1)
        end)

        it("http request", function ()
            -- given
            ssl = false
            local handle = handlerMock(headers, metadata, ssl)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "POST",
                "/path?query=val",
                "127.1.1.3",
                "service-first",
                "http",
                "",
                "403",
                false,
                false,
                "denied",
                "authority",
                "lua_authority"
            ))
            assert.spy(handle.logInfo).was_called(1)
        end)

        it("as logged when status code is different than 403", function ()
            -- given
            headers[':status'] = '503'
            local handle = handlerMock(headers, metadata, ssl)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "POST",
                "/path?query=val",
                "127.1.1.3",
                "service-first",
                "https",
                "",
                "503",
                false,
                false,
                "shadow_denied",
                "authority",
                "lua_authority"
            ))
            assert.spy(handle.logInfo).was_called(1)
        end)

        it("as logged when status code is 405 and proper headers should be set", function ()
            -- given
            headers[':status'] = "405"

            local filter_metadata = {
                ['service_name'] = "service",
            }

            local handle = handlerMock(headers, metadata, ssl, filter_metadata)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "POST",
                "/path?query=val",
                "127.1.1.3",
                "service-first",
                "https",
                "",
                "405",
                false,
                false,
                "shadow_denied",
                "authority",
                "lua_authority"
            ))
            assert.are.equal(headers["x-envoy-wrong-destination-reached"], "service")
            assert.are.equal(headers["x-envoy-wrong-destination-target"], "authority")
            assert.are.equal(headers["x-envoy-wrong-lua-destination-target"], "lua_authority")

            assert.spy(handle.logInfo).was_called(1)
        end)

        it("allowed & logged request", function ()
            -- given
            headers[':status'] = '200'
            headers['x-envoy-upstream-service-time'] = '10'
            local handle = handlerMock(headers, metadata, ssl)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "POST",
                "/path?query=val",
                "127.1.1.3",
                "service-first",
                "https",
                "",
                "200",
                false,
                false,
                "shadow_denied",
                "authority",
                "lua_authority"
            ))
            assert.spy(handle.logInfo).was_called(1)
        end)

        it("request with no lua filter metadata fields saved", function ()
            -- given
            metadata['envoy.filters.http.lua'] = {}
            headers = {}
            local handle = handlerMock(headers, metadata, ssl)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "",
                "",
                "",
                "",
                "https",
                "",
                "0",
                false,
                false,
                "shadow_denied",
                "",
                ""
            ))
            assert.spy(handle.logInfo).was_called(1)
        end)

        it("request with no lua filter metadata saved", function ()
            -- given
            metadata['envoy.filters.http.lua'] = nil
            headers = {}
            local handle = handlerMock(headers, metadata, ssl)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "",
                "",
                "",
                "",
                "https",
                "",
                "0",
                false,
                false,
                "shadow_denied",
                "",
                ""
            ))
            assert.spy(handle.logInfo).was_called(1)
        end)

        it("request with empty path", function ()
            -- given
            metadata['envoy.filters.http.lua']['request.info.path'] = ''
            local handle = handlerMock(headers, metadata, ssl)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "POST",
                "",
                "127.1.1.3",
                "service-first",
                "https",
                "",
                "403",
                false,
                false,
                "denied",
                "authority",
                "lua_authority"
            ))
            assert.spy(handle.logInfo).was_called(1)
        end)
    end)

    describe("should log requests:", function()

        it("with globally allowed client", function ()
            -- given
            metadata['envoy.filters.http.rbac']['shadow_engine_result'] = 'denied'
            metadata['envoy.filters.http.lua']['request.info.allowed_client'] = true
            headers['x-envoy-upstream-service-time'] = '10'
            local handle = handlerMock(headers, metadata, ssl)

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_called_with(_, formatLog(
                "POST",
                "/path?query=val",
                "127.1.1.3",
                "service-first",
                "https",
                "",
                "403",
                false,
                true,
                "shadow_denied",
                "authority",
                "lua_authority"
            ))
            assert.spy(handle.logInfo).was_called(1)
        end)
    end)

    describe("should not log requests:", function()

        it("request with no rbac metadata", function()
            -- given
            metadata = {}
            local handle = handlerMock(headers, metadata, ssl)
            local metadataMock = handle:streamInfo():dynamicMetadata()

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_not_called()
        end)

        it("authorized request", function()
            -- given
            metadata['envoy.filters.http.rbac']['shadow_engine_result'] = 'allowed'
            local handle = handlerMock(headers, metadata, ssl)
            local metadataMock = handle:streamInfo():dynamicMetadata()

            -- when
            envoy_on_response(handle)

            -- then
            assert.spy(handle.logInfo).was_not_called()
        end)
    end)

    describe("should handle x-forwarded-for formats:", function ()
        local xff_to_expected_client_ip= {
            {"", ""},
            {"127.9.3.2", "127.9.3.2"},
            {"3.23.2.44 , 2.34.3.2,127.1.3.5", "127.1.3.5"},
            {"2001:db8:85a3:8d3:1319:8a2e:370:7348,1001:db8:85a3:8d3:1319:8a2e:370:2222", "1001:db8:85a3:8d3:1319:8a2e:370:2222"},
            {"2001:db8:85a3:8d3:1319:8a2e:370:7348,127.1.3.4", "127.1.3.4"}
        }

        for i,v in ipairs(xff_to_expected_client_ip) do
            local xff = v[1]
            local expected_client_ip = v[2]

            it("'"..xff.."' -> '"..expected_client_ip.."'", function ()
                -- given
                metadata['envoy.filters.http.lua']['request.info.xff_header'] = xff
                local handle = handlerMock(headers, metadata, ssl)

                -- when
                envoy_on_response(handle)

                -- then
                assert.spy(handle.logInfo).was_called_with(_, contains("\"clientIp\": \""..expected_client_ip.."\""))
            end)
        end
    end)
end)

--[[
tools:
  show spy calls:
    require 'pl.pretty'.dump(handle.logInfo.calls, "/dev/stderr")
]] --
