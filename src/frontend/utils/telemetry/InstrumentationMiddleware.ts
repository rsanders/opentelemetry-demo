// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import { NextApiHandler } from 'next';
import {context, Exception, Span, SpanStatusCode, trace} from '@opentelemetry/api';
import { ATTR_HTTP_ROUTE, SemanticAttributes } from '@opentelemetry/semantic-conventions';

// route must be the API's path pattern (e.g. "/api/products/{productId}"), not the raw
// request URL, so http.route stays low-cardinality across dynamic path segments. Set before
// the handler runs so it lands on both the span and the http.server.request.duration metric,
// which is only annotated with http.route if the span already carries it by response finish.
const InstrumentationMiddleware = (route: string, handler: NextApiHandler): NextApiHandler => {
  return async (request, response) => {
    const span = trace.getSpan(context.active()) as Span;
    span.setAttribute(ATTR_HTTP_ROUTE, route);

    let httpStatus = 200;
    try {
      await runWithSpan(span, async () => handler(request, response));
      httpStatus = response.statusCode;
    } catch (error) {
      span.recordException(error as Exception);
      span.setStatus({ code: SpanStatusCode.ERROR });
      httpStatus = 500;
      throw error;
    } finally {
      span.setAttribute(SemanticAttributes.HTTP_STATUS_CODE, httpStatus);
    }
  };
};

async function runWithSpan(parentSpan: Span, fn: () => Promise<unknown>) {
  const ctx = trace.setSpan(context.active(), parentSpan);
  return await context.with(ctx, fn);
}

export default InstrumentationMiddleware;
