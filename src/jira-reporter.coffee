# Description
#   Compiles data from JIRA into daily reports
#
# Configuration:
#   LIST_OF_ENV_VARS_TO_SET
#
# Commands:
#   hubot hello - <what the respond trigger does>
#   orly - <what the hear trigger does>
#
# Notes:
#   <optional notes required for the script>
#
# Author:
#   Chris Downie <cdownie@gmail.com>


btoa       = require 'btoa'
# cronParser = require 'cron-parser'
moment     = require 'moment'
# schedule   = require 'node-schedule'
# Promise    = require 'promise'
# _          = require 'underscore'

jiraUrl = process.env.HUBOT_JIRA_URL
projectId = process.env.HUBOT_JIRA_PROJECT_ID
userGroup = process.env.HUBOT_JIRA_REPORT_USER_GROUP
authPayload = () ->
  username = process.env.HUBOT_JIRA_USERNAME
  password = process.env.HUBOT_JIRA_PASSWORD

  if username? and password?
    return btoa "#{username}:#{password}"
  else
    return null



# 4 questions
# 1. Does everyone have something in progress?
# 2. Does all in-progress stuff have an owner?
# 3. What *stories* have been closed in the last day?
# 4. Have all in-progress issues had their time tracking updated?

# what sprints are active?
# who's in jira?
#
# Interactions!!
# show jira closed stories
# Closed Stories:
#   * ID - Title
#   * ID - Title
#
# show jira in progress
# In Progress tasks:
#   * @assigned - 3h remaining on ID - Title
#   * @assigned - 16h remaining on ID - Title
#      \-> Not updated since yesterday. http://link
#   * *unassigned* - 30h remaining -
#
# show jira free agents
# Free agents: Sullins, Maclemnore, Lacoste
#
# show jira report
# Closed Stories:
#   * ID - Title
#   * ID - Title
# In Progress tasks:
#   * @assigned - 3h remaining on ID - Title
#   * @assigned - 16h remaining on ID - Title
#      \-> Not updated since yesterday. http://link
#   * *unassigned* - 30h remaining -
# Free agents: Sullins, Maclemnore, Lacoste



# Check if all the required environment variables have been set.
isConfiguredCorrectly = (res) ->
  errors = []

  if !jiraUrl?
    errors.push "Missing HUBOT_JIRA_URL environment variable"
  if !process.env.HUBOT_JIRA_USERNAME?
    errors.push "Missing HUBOT_JIRA_USERNAME environment variable"
  if !process.env.HUBOT_JIRA_PASSWORD?
    errors.push "Missing HUBOT_JIRA_PASSWORD environment variable"
  if !process.env.HUBOT_JIRA_PROJECT_ID?
    errors.push "Missing HUBOT_JIRA_PROJECT_ID environment variable"

  if errors.length > 0
    res.send errors.join('\n')
    return false
  return true

#
# All fetch* methods return promises. They make calls to get specific data from the JIRA api.
#
fetchSprints = (robot) ->
  sprintsJql = "project = #{projectId} and Sprint not in closedSprints()"
  requestUrl = "#{jiraUrl}/rest/greenhopper/1.0/integration/teamcalendars/sprint/list?jql=#{sprintsJql}"

  return new Promise (resolve, reject) ->
    robot.http(requestUrl)
      .header('Authorization', "Basic #{authPayload()}")
      .get() (err, resp, body) ->
        try
          bodyObj = JSON.parse(body)
          sprints = bodyObj.sprints || []
          resolve sprints
        catch error
          reject error

fetchUser = (robot, user) ->
  requestUrl = "#{jiraUrl}/rest/api/2/user?key=#{user.key}&expand=groups"

  return new Promise (resolve, reject) ->
    robot.http(requestUrl)
      .header('Authorization', "Basic #{authPayload()}")
      .get() (err, resp, body) ->
        try
          user = JSON.parse(body)
          resolve user
        catch error
          reject error

fetchUsers = (robot) ->
  # The correct way to get users by a group is with the /group?groupname=developers API.
  # Unfortunately, that requires the caller to have admin priviledges. This makes tons of
  # calls to the /user api to filter down to the userGroup, if it exists.
  requestUrl = "#{jiraUrl}/rest/api/2/user/assignable/search?project=#{projectId}"

  return new Promise (resolve, reject) ->
    robot.http(requestUrl)
      .header('Authorization', "Basic #{authPayload()}")
      .get() (err, resp, body) ->
        try
          users = JSON.parse(body)

          if userGroup?
            # Filter by userGroup if it exists
            userPromises = users.map (user) ->
              return fetchUser(robot, user)
            Promise.all(userPromises)
              .then (users) ->
                filteredUsers = users.filter (user) ->
                  groups = user.groups.items || []
                  groups.find (group) ->
                    group.name == userGroup

                resolve filteredUsers
              .catch (error) ->
                reject error

          else
            resolve users
        catch error
          reject error

fetchInProgressSubtasks = (robot) ->

  return fetchSprints(robot)
    .then (sprints) ->
      sprintIds = sprints.map( (sprint) -> sprint.id ).join(',')
      jql = "project in (#{projectId}) AND issuetype = Sub-task AND status = \"In Progress\" AND Sprint in (#{sprintIds})"
      requestUrl = "#{jiraUrl}/rest/api/2/search?jql=#{jql}"

      new Promise (resolve, reject) ->
        robot.http(requestUrl)
          .header('Authorization', "Basic #{authPayload()}")
          .get() (err, resp, body) ->
            try
              bodyObj = JSON.parse(body)
              issues = bodyObj.issues || []
              resolve issues
            catch error
              reject error
#
# generate*Report methods all return a string with a specific report type
#
generateInProgressReport = (inProgressIssues) ->
  # Example output:
  #
  # In Progress tasks:
  #   * @assigned - 3h remaining on ID - Title
  #   * @assigned - 16h remaining on ID - Title
  #      \-> Not updated since yesterday. http://link
  #   * *unassigned* - 30h remaining -
  sortedIssues = inProgressIssues.sort (leftIssue, rightIssue) ->
    leftAssignee = leftIssue.fields.assignee
    rightAssignee = rightIssue.fields.assignee
    if leftAssignee?
      if rightAssignee?
        # We have 2 actual users. Let's compare keys.
        if leftAssignee.key < rightAssignee.key
          return -1
        else if leftAssignee > rightAssignee
          return 1
        return 0
      else
        return 1
    else
      if rightAssignee?
        return -1
      return 0


  renderedList = sortedIssues.map (issue) ->
    # Useful computed data
    issueLink = "#{jiraUrl}/browse/#{issue.key}"
    secondsLeft = issue.fields.progress.total - issue.fields.progress.progress
    updatedAgo = moment.duration(moment().diff(moment('2016-04-19T15:27:58.000-0700')))

    if issue.fields.assignee?
      assigneeString = issue.fields.assignee.name
    else
      assigneeString = "unassigned"
    timeRemaining = "#{moment.duration(secondsLeft, 'seconds') .asHours()}h remaining"

    # Issue warnings
    hasntBeenUpdatedIn24hours = updatedAgo.asHours() > 24
    isUnassigned = !issue.fields.assignee?
    shouldBeResolved = secondsLeft <= 0

    # Bold any concerning fields
    if isUnassigned
      assigneeString = "*#{assigneeString}*"
    if secondsLeft <= 0
      timeRemaining = "*#{timeRemaining}*"

    # Main line rendering
    renderedIssue = "\t#{assigneeString} - #{timeRemaining} - #{issue.key}"

    # Show any warnings with the issue link
    if shouldBeResolved
      renderedIssue += "\n\t\t↳ Should this be marked as Completed? #{issueLink}"
    else if isUnassigned
      renderedIssue += "\n\t\t↳ Who's working on this? #{issueLink}"
    else if hasntBeenUpdatedIn24hours
      renderedIssue += "\n\t\t↳ This hasn't been updated since yesterday. #{issueLink}"

    return renderedIssue

  return "In progress tasks:\n#{renderedList.join('\n')}"
#
# Robot listening registry
#
module.exports = (robot) ->

  robot.respond /show jira sprints/i, (res) ->
    fetchSprints(robot)
      .then (sprints) ->
        res.send "Sprints: #{sprints.map((sprint) -> sprint.id).join(', ')}"
      .catch (error) ->
        res.send "Whoops. #{error.message}"

  robot.respond /show jira users/i, (res) ->
    fetchUsers(robot)
      .then (users) ->
        res.send "Users: #{users.map((user) -> user.name).join(', ')}"
      .catch (error) ->
        res.send "Whoops. #{error.message}"

  robot.respond /show jira in progress/i, (res) ->
    fetchInProgressSubtasks(robot)
      .then (subtasks) ->
        report = generateInProgressReport(subtasks)
        res.send report
      .catch (error) ->
        res.send "Whoops. #{error.message}"

  robot.respond /check/i, (res) ->
    if !isConfiguredCorrectly(res)
      return


    # Find the currently open Sprint


    data =
      jql: "project in (#{projectId}) AND status = \"In Progress\" AND Sprint in (80)"
      fields: 'key'
    requestUrl = "#{jiraUrl}/rest/api/2/search?jql=#{data.jql}&fields=#{data.fields}"

    robot.http(requestUrl)
      .header('Authorization', "Basic #{authPayload()}")
      .get() (err, resp, body)->
        bodyObj = JSON.parse(body)
        howMany = bodyObj.total
        res.send "Found #{howMany} issues: #{bodyObj.issues.length}"

        res.send bodyObj.issues.map( (issue) -> issue.key ).join(', ')
