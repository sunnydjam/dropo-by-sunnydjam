# Corresponding source/build recipe for the legacy security compatibility image.
FROM gozargah/marzban@sha256:8e422c21997e5d2e3fa231eeff73c0a19193c20fc02fa4958e9368abb9623b8d AS upstream
FROM python@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df AS wheels
COPY bootstrap.lock requirements.lock /locks/
RUN python -m pip install --no-cache-dir --require-hashes --no-deps -r /locks/bootstrap.lock \
 && python -m pip wheel --no-cache-dir --require-hashes --no-build-isolation --no-deps -r /locks/requirements.lock --wheel-dir /wheels

FROM python@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df
COPY --from=upstream /code /code
COPY --from=wheels /wheels /wheels
RUN python -m pip install --no-cache-dir --no-index --no-deps /wheels/*.whl \
 && python -m pip check \
 && rm -rf /wheels
COPY app_routes_patch.py /tmp/dropo-compat/
COPY deployed_core.py /code/app/xray/core.py
RUN python -c "from pathlib import Path;import runpy;p=Path('/code/app/__init__.py');p.write_text(runpy.run_path('/tmp/dropo-compat/app_routes_patch.py')['apply'](p.read_text()))"
ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /code
ENTRYPOINT ["/bin/bash", "-c"]
CMD ["alembic upgrade head && exec python main.py"]
