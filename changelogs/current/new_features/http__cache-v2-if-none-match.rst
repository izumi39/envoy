The ``cache_v2`` filter now evaluates request ``If-None-Match`` using weak comparison and can
serve ``304 Not Modified`` from cache. See
`RFC 9110 Section 13.1.2 <https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.2>`_.

Requests that include ``If-Modified-Since`` still bypass the cache, including when
``If-None-Match`` is also present. ``If-Modified-Since`` remains an unimplemented precondition, so
the filter forwards the request rather than serving it from cache. This does not produce incorrect
cached responses; it only reduces cache effectiveness. See
`RFC 9111 Section 4.3 <https://www.rfc-editor.org/rfc/rfc9111.html#section-4.3>`_ and
`RFC 9110 Section 13.1.3 <https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.3>`_.
