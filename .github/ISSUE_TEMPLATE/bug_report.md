---
name: Bug report
about: Create a report to help us improve
title: ''
labels: ''
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**Puma config:**

Please copy-paste your Puma config or your command line options here.

**To Reproduce**
Please add reproduction steps here.

Your issue will be solved very quickly if you can reproduce it with a "hello world" rack application. To do this, copy this into a file called `hello.ru`:

```
run lambda { |env| [200, {"Content-Type" => "text/plain"}, ["Hello World"]] }
```

Run it with:

```
bundle exec puma -C <where_your_config_is> hello.ru
```

If you cannot reproduce with a hello world application or other simple application, we will have a lot more difficulty helping you fix your issue, because it may be application-specific and not a bug in Puma at all. 

**Expected behavior**
A clear and concise description of what you expected to happen.

**Desktop (please complete the following information):**
 - OS: [e.g. Mac, Linux]
 - Puma Version [e.g. 4.1.1]
