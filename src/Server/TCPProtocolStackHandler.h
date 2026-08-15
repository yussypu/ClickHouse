#pragma once

#include <Server/TCPServerConnectionFactory.h>
#include <Server/TCPServer.h>
#include <Poco/Util/LayeredConfiguration.h>
#include <Server/IServer.h>
#include <Server/TCPProtocolStackData.h>

#include <optional>


namespace DB
{


class TCPProtocolStackHandler : public Poco::Net::TCPServerConnection
{
    using StreamSocket = Poco::Net::StreamSocket;
    using TCPServerConnection = Poco::Net::TCPServerConnection;
private:
    IServer & server;
    TCPServer & tcp_server;
    std::vector<TCPServerConnectionFactory::Ptr> stack;
    std::string conf_name;
    bool is_introspection;
    std::optional<std::string> default_database;

public:
    TCPProtocolStackHandler(
        IServer & server_,
        TCPServer & tcp_server_,
        const StreamSocket & socket,
        const std::vector<TCPServerConnectionFactory::Ptr> & stack_,
        const std::string & conf_name_,
        bool is_introspection_,
        std::optional<std::string> default_database_)
        : TCPServerConnection(socket)
        , server(server_)
        , tcp_server(tcp_server_)
        , stack(stack_)
        , conf_name(conf_name_)
        , is_introspection(is_introspection_)
        , default_database(std::move(default_database_))
    {
    }

    void run() override
    {
        const auto & conf = server.config();
        TCPProtocolStackData stack_data;
        stack_data.socket = socket();
        stack_data.default_database = default_database.value_or(conf.getString(conf_name + ".default_database", ""));
        stack_data.is_introspection = is_introspection;
        for (auto & factory : stack)
        {
            std::unique_ptr<TCPServerConnection> connection(factory->createConnection(socket(), tcp_server, stack_data));

            if (!connection)
                return;

            connection->run();
            if (stack_data.socket != socket())
                socket() = stack_data.socket;
        }
    }
};


}
