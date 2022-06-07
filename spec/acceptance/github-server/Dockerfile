FROM ruby:2.4.4
LABEL maintainer="GitHub Security Ops <opensource+entitlements-app@github.com>"

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
