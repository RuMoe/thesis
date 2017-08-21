// Copyright 2015 Zuse Institute Berlin
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
//
//        http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.

#include "connection.hpp"

namespace scalaris {

  Connection::Connection(std::string _hostname,
                         std::string _link,
                         std::string port)
    : socket(ioservice), hostname(_hostname), link(_link) {
    using boost::asio::ip::tcp;

    // Determine the location of the server.
    tcp::resolver resolver(ioservice);
    tcp::resolver::query query(hostname, port);
    tcp::resolver::iterator endpoint_iterator = resolver.resolve(query);

    // Try each endpoint until we successfully establish a connection.
    boost::system::error_code ec;
    boost::asio::connect(socket, endpoint_iterator, ec);
    if(ec) {
      std::cout << ec.message() << std::endl;
      throw ConnectionError(ec.message());
    }
  }

  Connection::~Connection() {
    if(!closed) {
      boost::system::error_code ec;
      socket.close(ec);
    }
  }

  bool Connection::isOpen() const {
    return socket.is_open();
  };

  void Connection::close() {
    socket.close();
    closed=true;
  };

  std::string Connection::get_port() {
    char *port = getenv("SCALARIS_UNITTEST_YAWS_PORT");
    if(port == NULL)
      return std::string("8000");
    else
      return std::string(port);
  }

  Json::Value Connection::exec_call(const std::string& methodname, Json::Value params) {
    Json::Value call;
    call["method"]=methodname;
    call["params"]=params;
    call["id"]=0;
    std::stringstream json_call;
    Json::StreamWriterBuilder builder;
    std::unique_ptr<Json::StreamWriter> writer(builder.newStreamWriter());
    writer->write(call, &json_call);
    std::string json_call_str = json_call.str();

    boost::asio::streambuf request;
    std::ostream request_stream(&request);
    request_stream << "POST /" << link << " HTTP/1.1\r\n";
    request_stream << "Host: " << hostname << "\r\n";
    request_stream << "Content-Type: application/json-rpc\r\n";
    request_stream << "Content-Length: " << json_call_str.size() << "\r\n";
    request_stream << "Connection: keep-alive\r\n\r\n";
    request_stream << json_call_str << "\r\n\r\n";

    // Send the request.
    boost::system::error_code ec;
    boost::asio::write(socket, request, ec);
    if(ec) {
      std::cout << ec.message() << std::endl;
      throw ConnectionError(ec.message());
    }

    boost::asio::streambuf response;
    boost::asio::read_until(socket, response, "\r\n");
    // Check that response is OK.
    std::istream response_stream(&response);
    std::string http_version;
    response_stream >> http_version;
    unsigned int status_code;
    response_stream >> status_code;
    std::string status_message;
    std::getline(response_stream, status_message);
    if (!response_stream || http_version.substr(0, 5) != "HTTP/")
      {
        std::cout << "Invalid response\n";
        throw ConnectionError("Invalid response");
      }
    if (status_code != 200)
      {
        std::cout << "Response returned with status code " << status_code << "\n";
        std::stringstream error;
        error << "Response returned with status code " << status_code;
        throw ConnectionError(error.str());
      }

    // Read the response headers, which are terminated by a blank line.
    boost::asio::read_until(socket, response, "\r\n\r\n");
    // Process the response headers.
    std::string header;
    std::stringstream header_stream;
    while (std::getline(response_stream, header) && header != "\r")
      header_stream << header << "\n";
    header_stream << "\n";

    std::stringstream json_result;
    // Write whatever content we already have to output.
    if (response.size() > 0)
      json_result << &response;

    Json::CharReaderBuilder reader_builder;
    reader_builder["collectComments"] = false;
    Json::Value value;
    std::string errs;
    bool ok = Json::parseFromStream(reader_builder, json_result, &value, &errs);
    if(!ok) {
      throw ConnectionError(errs);
    }

    return process_result(value);
  }

  Json::Value Connection::process_result(const Json::Value& value) {
    if(value.isObject()) {
      Json::Value id = value["id"];
      if(!id.isIntegral() or id.asInt() != 0) {
        std::stringstream error;
        error << value.toStyledString() << " is no id=0";
        throw ConnectionError(error.str());
      }
      Json::Value jsonrpc = value["jsonrpc"];
      if(!jsonrpc.isString()) {
        std::stringstream error;
        error << value.toStyledString() << " has no string member: jsonrpc";
        throw ConnectionError(error.str());
      }
      Json::Value result = value["result"];
      if(!result.isObject()) {
        std::stringstream error;
        error << value.toStyledString() << " has no object member: result";
        throw ConnectionError(error.str());
      }
      return result;
    } else {
      std::stringstream error;
      error << value.toStyledString() << " is no json object";
      throw ConnectionError(error.str());
    }
  }
}
