FROM gcr.io/forgerock-io/ds-empty/pit1:7.0.0-b134ec4a77a17cf37dd82a31c6760211316bd57c
USER root
RUN chown -R forgerock:root /opt/opendj
USER forgerock
COPY --chown=forgerock:root idrepo /opt/opendj/
COPY --chown=forgerock:root scripts /opt/opendj/scripts
ARG profile_version
RUN bin/setup.sh "$profile_version"  && rm bin/setup.sh
