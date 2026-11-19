#!/usr/bin/python

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

import asyncio
from contextlib import AsyncExitStack
import logging

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


class MCPClient:
    def __init__(self, url):
        self.url = url
        self.exit_stack = AsyncExitStack()
        self.session = None
        self._lock = asyncio.Lock()

    async def connect_to_mcp_server(self):
        stream_context = streamablehttp_client(url=self.url)
        read, write, _ = await self.exit_stack.enter_async_context(stream_context)
        session_context = ClientSession(read, write)
        self.session = await self.exit_stack.enter_async_context(session_context)
        await self.session.initialize()

    async def reconnect(self):
        async with self._lock:
            await self.cleanup()
            self.exit_stack = AsyncExitStack()
            await self.connect_to_mcp_server()

    async def ensure_session(self):
        if self.session is None:
            await self.reconnect()
        return self.session

    async def cleanup(self):
        try:
            await self.exit_stack.aclose()
        except BaseException as e:
            logging.error(f"Error closing connection : {e}")
        finally:
            self.session = None
