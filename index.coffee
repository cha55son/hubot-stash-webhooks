# Description:
#   Accepts Atlassian Stash post commit webhook POSTs and delivers to XMPP chat
#
# Dependencies:
#   None
#
# Configurations:
#   STASH_HOST_URL    - The URL to your stash instance.
#   STASH_ROOM_SUFFIX - To be appended to the end of the roomname. 
#                       Ex. roomname        = webapps 
#                           roomname_suffix = @conference.digitalreasoning.com
#                           full_roomname   = webapps@conference.digitalreasoning.com
#   STASH_JIRA_URL    - The URL to your JIRA instance. This env var will check the other following
#                       env vars before reading this env var:
#                       STASH_JIRA_URL = STASH_JIRA_URL || HUBOT_JIRA_URL || JIRA_HOST_URL
#
# Commands:
#
# Notes:
#   Setup Stash to submit a webhook to http://<hubot host>:<port>/stash/webhooks/<room name>
#
# Author:
#   Kyle Guichard (kgsharp)
#   Chason Choate (cha55son)
ltx = require 'ltx'
path = require 'path'
fs = require 'fs'

module.exports = (robot) ->
  STASH_URL   = process.env.STASH_HOST_URL
  ROOM_SUFFIX = process.env.STASH_ROOM_SUFFIX
  JIRA_URL    = process.env.STASH_JIRA_URL || process.env.HUBOT_JIRA_URL || process.env.JIRA_HOST_URL

  envs_valid = ->
    if !STASH_URL || !ROOM_SUFFIX
      robot.logger.warning "You are using the stash.coffee script but do not have all env vars defined."
      robot.logger.warning "STASH_PROJECTS_URL and/or STASH_ROOM_SUFFIX are not defined. Define them in config.sh."
      false
    else
      true
  envs_valid()

  robot.router.post '/stash/webhooks/:room', (req, res) ->
    return unless envs_valid()

    room = req.params.room
    json = JSON.stringify(req.body)
    message = JSON.parse json

    if process.env.DEBUG?
      webhook_name = 'webhook-' + Math.floor(Date.now() / 1000) + '.json'
      fs.writeFile path.resolve(__dirname + '/logs/' + webhook_name), JSON.stringify(req.body, null, 4), (err) ->
        return console.log(err) if err
        robot.logger.info "Stash webhook data written to: logs/#{webhook_name}"

    text = ''
    html = ''
    project_url = "#{STASH_URL}/projects/#{message.repository.project.key}/"
    repo_url = "#{project_url}repos/#{message.repository.slug}/"

    message.refChanges.forEach (ref) ->
      action = ref.type.toLowerCase()
      name = ref.refId.replace('refs/tags/', '').replace('refs/heads/', '')
      url = "#{repo_url}commits?until=#{name}"
      type = if ref.refId.match('refs/tags/') then 'tag' else 'branch'
      repo_name = "#{message.repository.project.name}/#{message.repository.name}"
      html_repo_link = "<a href='#{project_url}'>#{message.repository.project.name}</a>/<a href='#{repo_url}'>#{message.repository.name}</a>" 

      if action == 'add'
        text += "➕ Created #{type} #{url} on #{repo_name}"
        html += "➕ Created #{type} <a href='#{url}'>#{name}</a> on #{html_repo_link}"
      else if action == 'delete'
        text += "➖ Deleted #{type} #{name} on #{repo_name}"
        html += "➖ Deleted #{type} <em>#{name}</em> on #{html_repo_link}"
      else if action == 'update'
        text += "➜ Updated branch #{name} on #{repo_name}"
        html += "➜ Updated branch <a href='#{url}'>#{name}</a> on #{html_repo_link}"
      else
        robot.logger.error "Do not recognize ref action '#{action}'"
        robot.logger.error json
        return

      if type == 'branch' 
        if message.changesets.values.length > 0
          html += '<br/>'
          text += "\n"
        subset = message.changesets.values.slice(0, 3)
        subset.forEach (changeset, i, arr) ->
          user_link = "#{STASH_URL}/users/#{changeset.toCommit.author.emailAddress.split('@')[0]}"
          text += "#{changeset.toCommit.author.name} - #{changeset.toCommit.message} #{changeset.links.self}"
          text += "\n" unless i == arr.length - 1
          # Replace newlines with <br/>. 
          msg = changeset.toCommit.message.replace(/\n/g, "<br/>")
          # Replace JIRA issues with links.
          if JIRA_URL
            msg = msg.replace /([a-zA-Z]{2,10}-[0-9]+)/g, (match, p1) ->
              "<a href='#{JIRA_URL}/browse/#{match}'>#{match}</a>" 
          html += "<a href='#{user_link}'>#{changeset.toCommit.author.name}</a> <em>#{msg}</em> " +
                  "(<a href='#{changeset.links.self[0].href}'>#{changeset.toCommit.displayId}</a>)"
          html += "<br/>" unless i == arr.length - 1
        if message.changesets.values.length > subset.length
          left = message.changesets.values.length - subset.length
          text += "\nand #{left} more commit#{ if left == 1 then '' else 's' }"
          html += "<br/><em>and #{left} more commit#{ if left == 1 then '' else 's' }</em>"

    # Build the HTML XMPP response
    message = "<message>" +
                "<body>#{text}</body>" +
                "<html xmlns='http://jabber.org/protocol/xhtml-im'>" + 
                  "<body xmlns='http://www.w3.org/1999/xhtml'>#{html}</body>" +
                "</html>" + 
              "</message>"
    user = robot.brain.userForId 'broadcast'
    user.room = room + ROOM_SUFFIX
    user.type = 'groupchat'
    robot.send user, ltx.parse(message)

    # Respond to request
    res.writeHead 200, { 'Content-Type': 'text/plain' }
    res.end 'Thanks'
