FROM ruby:3.3-slim
LABEL maintainer="GitHub Security Ops <opensource+entitlements-app@github.com>"

# Install dependency packages for bootstrapping and running...
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    cmake \
    gcc \
    git \
    ldap-utils \
    make \
    iputils-ping \
    pkg-config

# Install gems
ENV APP_HOME /app
ENV HOME /root
RUN mkdir $APP_HOME
WORKDIR $APP_HOME
COPY Gemfile* $APP_HOME/
RUN bundle install

# Upload source
COPY . $APP_HOME

# Start server
ENV PORT 443
EXPOSE 443
CMD ["./run.sh"]
