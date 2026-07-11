//
// oracle.cpp — a small, self-contained golden oracle over the SAME Boost.Beast HTTP parse path the
// fuzzers exercise (http::request_parser / http::response_parser driven over a test::stream). It is
// additive (lives only in mayhem/) and does NOT use Beast's b2-based unit suite.
//
// It asserts real parser behaviour:
//   1. a well-formed GET request parses, exposing the correct method / target / version / a header,
//      and the parser reaches is_done() with no error;
//   2. a well-formed chunked request body is decoded to the expected payload;
//   3. a well-formed 200 response parses, exposing the status code / reason / a header;
//   4. a MALFORMED request line is REJECTED (the parser surfaces an error rather than accepting it).
//
// Any change that breaks parsing of valid messages, mis-decodes a body, or starts accepting the
// malformed case fails the oracle — so a no-op / exit(0) patch cannot pass. Result is printed as a
// "PASS"/"FAIL" line per case; mayhem/test.sh tallies them into a CTRF summary.
//
#include <boost/beast/http.hpp>
#include <boost/beast/_experimental/test/stream.hpp>

#include <cstdio>
#include <string>

namespace beast = boost::beast;
namespace http  = beast::http;

static int g_pass = 0;
static int g_fail = 0;

static void check(const char* name, bool ok)
{
    if (ok) { ++g_pass; std::printf("PASS %s\n", name); }
    else    { ++g_fail; std::printf("FAIL %s\n", name); }
}

// Parse `wire` as a request using request_parser; returns true iff the whole message parsed cleanly.
template <class Parser>
static bool feed(Parser& parser, const std::string& wire)
{
    beast::error_code ec;
    beast::flat_buffer buffer;
    boost::asio::io_context ioc;
    beast::test::stream stream{ioc, wire};
    stream.close_remote();
    http::read(stream, buffer, parser, ec);
    return !ec;
}

int main()
{
    // 1) well-formed GET request: fields are parsed correctly.
    {
        http::request_parser<http::string_body> parser;
        const std::string wire =
            "GET /index.html HTTP/1.1\r\n"
            "Host: example.com\r\n"
            "Accept: text/html\r\n"
            "\r\n";
        bool ok = feed(parser, wire);
        const auto& req = parser.get();
        check("request: parses without error", ok);
        check("request: method == GET",      req.method() == http::verb::get);
        check("request: target == /index.html", req.target() == "/index.html");
        check("request: version == 1.1",     req.version() == 11);
        check("request: Host header",         req[http::field::host] == "example.com");
        check("request: is_done",             parser.is_done());
    }

    // 2) well-formed chunked request body decodes to the expected payload.
    {
        http::request_parser<http::string_body> parser;
        const std::string wire =
            "POST /upload HTTP/1.1\r\n"
            "Host: example.com\r\n"
            "Transfer-Encoding: chunked\r\n"
            "\r\n"
            "4\r\nWiki\r\n"
            "5\r\npedia\r\n"
            "0\r\n\r\n";
        bool ok = feed(parser, wire);
        const auto& req = parser.get();
        check("chunked: parses without error", ok);
        check("chunked: body == 'Wikipedia'",  req.body() == "Wikipedia");
    }

    // 3) well-formed 200 response: status line is parsed correctly.
    {
        http::response_parser<http::string_body> parser;
        const std::string wire =
            "HTTP/1.1 200 OK\r\n"
            "Server: beast\r\n"
            "Content-Length: 5\r\n"
            "\r\n"
            "hello";
        bool ok = feed(parser, wire);
        const auto& res = parser.get();
        check("response: parses without error", ok);
        check("response: result == 200 OK",     res.result() == http::status::ok);
        check("response: Server header",         res[http::field::server] == "beast");
        check("response: body == 'hello'",       res.body() == "hello");
    }

    // 4) malformed request line is REJECTED (negative test — proves the oracle has teeth).
    {
        http::request_parser<http::string_body> parser;
        const std::string wire =
            "GET /index.html NOTAVERSION\r\n"   // bogus HTTP-version token
            "\r\n";
        bool ok = feed(parser, wire);  // ok==true would mean it wrongly accepted the garbage
        check("malformed: rejected", !ok);
    }

    std::printf("ORACLE_SUMMARY passed=%d failed=%d\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
