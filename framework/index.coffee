doctype 5
html ->
  head ->
    meta charset: 'utf-8'
    meta name:"viewport", content:"width=device-width, minimum-scale=1, maximum-scale=1"
    title "NRG Calculator"
    link rel: 'stylesheet', href: 'stylesheets/jquery.mobile.css'
    link rel: 'stylesheet', href: 'stylesheets/jqm-docs.css'
    script src: 'phonegap-1.0.0.js'
    script src: 'javascripts/jquery.js'
    script src: 'javascripts/jquery.mobile.js'
    script src: 'javascripts/dygraph-combined.js'
    script src: 'javascripts/spine.js'
    script src: 'javascripts/spine.local.js'
    script src: 'javascripts/coffeekup.js'
    script "var exports = this;"
    script "__bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; };"
    coffeescript ->


# models

      exports.Device = Spine.Model.setup "Device", ["scenario_id", "template_device_id", "suggestion_device_id", "name", "comment", "count", "rechargable", "min_burn", "max_burn", "on_bus_capacity", "off_bus_capacity", "operating_from", "operating_until", "units", "units_provided", "units_draw", "units_draw_charging", "capacity_unit_hours", "starting_fullness", "in_bus", "out_bus", "burner_btu", "current_unit_hours", "currently_operating", "units_committed"]
      Device.extend Spine.Model.Local

      Device.extend print: (label = "devices", all) ->
        console.log "-- #{label} --"
        device.print() for device in all

      Device.extend templates: ->
        Device.select (d) -> not d.scenario_id?

      Device.extend applyDraw: (bus, h, drains, providers) ->
        # failing device return indicates overdraw

        for slice in [1..10]
          device.units_committed = 0 for device in providers
          drains.sort (a,b) -> a.currentLevel() - b.currentLevel()
          providers.sort (a,b) -> a.currentLevel() - b.currentLevel()
          pcopy = providers.slice 0
          provider = pcopy.pop()
          for drain in drains
            if drain.can_operate_at(h)
              e = drain.units_draw * (drain.count ? 1)
              while e > 0
                return drain unless provider?
                e = provider.harvestWatts e, drain, 10
                provider = pcopy.pop() if e > 0
        null

      Device.include currentLevel: ->
        return 0 unless @units is "Watt"
        return 0 if @units_draw? or (@units_draw_charging? and @in_bus != @out_bus) # regular draining devices or rechargables that don't care what the bus voltage is
        return 1.1 unless @current_unit_hours? # solar and generator must kick in first
        @current_unit_hours / (@capacity_unit_hours * (@count ? 1))

      Device.include print: ->
        console.log "#{@name}"

      Device.include addWatts: (e, interval) ->
        if @current_unit_hours? and @rechargable?
          @current_unit_hours += e/interval
          @current_unit_hours = Math.min @current_unit_hours, @count * @capacity_unit_hours

      Device.include harvestWatts: (e, draw, interval) ->
        # current unit hours if battery
        if @current_unit_hours?
          s = e/interval
          if @current_unit_hours > s
            @current_unit_hours -= s
            draw.addWatts e, interval
            return 0
          else
            @current_unit_hours = 0
            return e

        # generating devices should check what they committed first
        available = @count * @units_provided - @units_committed
        if available > e
          @units_committed += e
          draw.addWatts e, interval
          e = 0
        else
          e -= available
          draw.addWatts available, interval
          @units_committed = @count * @units_provided
        e

      Device.include sometimes_off: ->
        @operating_from? or @min_burn?

      Device.include can_operate_at: (h) ->
        return true unless @operating_from?
        # true if h is between from and until
        skew = 24 - @operating_from
        (@operating_until + skew) % 24 > (h + skew) % 24

      Device.include operating_at: (h) ->
        return false if @currently_operating is false
        @can_operate_at(h)

      Device.include startgraphing: (a) ->
        @currently_operating = false if @min_burn
        if @capacity_unit_hours?
          a.push "#{@name}#{if @sometimes_off() then ' level' else ''}"
          @current_unit_hours = (@count * @capacity_unit_hours * (@starting_fullness ? 100)) / 100
        if @sometimes_off()
          a.push "#{@name}#{if @capacity_unit_hours? then ' on' else ''}"

      Device.include graphpoint: (a, h) ->
        if @capacity_unit_hours?
          a.push "#{@current_unit_hours / (@capacity_unit_hours * (@count ? 1))}"
        if @sometimes_off()
          a.push "#{if @operating_at(h) then 0.2 else 0.0 }"

      Device.include propaneDraw: (h) ->
        return 0 unless @operating_at h
        if @units is "BTU" and @units_draw?
          @units_draw
        else if @burner_btu?
          @burner_btu
        else
          0

      Device.include harvestBTU: (p) ->
        return 0 unless @units is "BTU"
        if @current_unit_hours >= p
          @current_unit_hours -= p
        else
          p = @current_unit_hours
          @current_unit_hours = 0
        p

      Device.include scenario: ->
        Scenario.find(@scenario_id)

      exports.Scenario = Spine.Model.setup "Scenario", ["name", "updated_at"]
      Scenario.extend Spine.Model.Local

      Scenario.include devices: ->
        Device.select (d) => d.scenario_id is @id

      Scenario.include addDeviceFromTemplate: (template, count = 1) ->
        template.dup(true).updateAttributes scenario_id: @id, count: count

      Scenario.include cdestroy: ->
        t.destroy() for t in @devices()
        @destroy()

      Scenario.include graphdata: ->
        all_devices = @devices()
        legend = ["Date"]
        device.startgraphing(legend) for device in all_devices
        data = legend.join(',') + "\n"

        # run simulation
        for d in [1..4]
          for h in [0..23]
            # add to graph record
            timestr = "2011-06-0#{d} #{h}:00"
            row = [timestr]
            console.log timestr
            device.graphpoint(row, h) for device in all_devices
            data += row.join(',') + "\n"

            # power fail
            powerfail = {}
            propanefail = {}

            # simulate one hour passing
            p = 0
            p += device.propaneDraw(h) for device in all_devices
            p -= device.harvestBTU(p) for device in all_devices

            propanefail[timestr] = true if p > 0

            electricals = (device for device in all_devices when device.units is "Watt")
            for bus in [0..5]
              draining = (device for device in electricals when device.in_bus is bus)
              providing = (device for device in electricals when device.out_bus is bus)

              if draining.length > 0 or providing.length > 0
                powerfail[timestr] ?= Device.applyDraw(bus, h, draining, providing)

        data

      Scenario.include annotations: ->
        [] #{series: "Temperature", x: "2008-05-08", shortText: "*", text: "event"}]

# views

      Device.extend indexView: (devicelist) ->
        CoffeeKup.render (->
          for d in @devices
            li ->
              count = if d.count? and d.count > 1 then " (#{d.count})" else ""
              a class: "devices", mid: "#{d.id}", href:"##{d.id}", "#{d.name} #{count}"),
          context: {devices: devicelist}

      Device.extend selectView: (devicelist = Device.templates()) ->
        CoffeeKup.render (->
          for d in @devices
            option value: "#{d.id}", "#{d.name}"), context: {devices: devicelist}

      Device.include showView: ->
        CoffeeKup.render (->
          div "data-role": "page", id: "#{@device.id}", "data-url": "#{@device.id}", ->
            div "data-role": "header", ->
              a href: "##{@device.scenario_id}", "data-icon": "arrow-l", "data-rel": "back", "data-iconpos": "notext"
              h1 "#{@device.name}"
              a href: "#menu1", "data-direction": "back", class: 'updatedevice', mid: "#{@device.id}", "Update" # href could be "##{@device.scenario_id}" or "#menu1"
            div "data-role": "content", ->
              div "data-role": "fieldcontain", ->
                for attr in Device.attributes when @device[attr]? and not attr.match(/_id/)
                  label for: "#{@device.id}-#{attr}", "#{attr}: "
                  input type: "text", name: "#{@device.id}-#{attr}", id: "#{@device.id}-#{attr}", value: "#{@device[attr]}"
            div "data-role": "footer", ->
              a href: "#menu1", "data-role": "button", mid: "#{@device.id}", class: "deletedevice", "Delete"), context: {device: @}

      Device.include liView: ->
        CoffeeKup.render (->
          li "data-theme": "c", class: "ui-btn ui-btn-icon-right ui-li ui-btn-down-c ui-btn-up-c", ->
            div class: "ui-btn-inner ui-li", ->
              div class: "ui-btn-text", ->
                a class: "devices ui-link-inherit", mid: "#{@device.id}", href: "##{@device.id}", "#{@device.name}"
              span class: "ui-icon ui-icon-arrow-r"), context: {device: @}

      Scenario.extend indexView: ->
        CoffeeKup.render ->
          Scenario.each (s) ->
            li "data-theme": "c", class: "ui-btn ui-btn-icon-right ui-li ui-btn-down-c ui-btn-up-c", ->
              div class: "ui-btn-inner ui-li", ->
                div class: "ui-btn-text", ->
                  a class: "scenarios ui-link-inherit", mid: "#{s.id}", href: "##{s.id}", "#{s.name}"
                span class: "ui-icon ui-icon-arrow-r"

      Scenario.include showView: ->
        CoffeeKup.render (->
          div "data-role": "page", id: "#{@scenario.id}", "data-url": "#{@scenario.id}", ->
            div "data-role": "header", ->
              a href: "#menu1", "data-icon": "home", "data-rel": "back", "data-iconpos": "notext"
              h1 "#{@scenario.name}"
              a href: "#newdevice", class: "ui-btn-right", "+"
            div "data-role": "content", ->
              div class: "content-secondary", ->
                ul "data-role": "listview", "#{@dlist}"
              div class: "content-primary", id: "#{@scenario.id}-graphdiv"
            div "data-role": "footer", ->
              a href: "#menu1", "data-role": "button", mid: "#{@scenario.id}", class: "deletescenario", "Delete this scenario"),
          context: {scenario: @, dlist: Device.indexView(@devices())}

# Controllers

      exports.Devices = Spine.Controller.create
        init: ->
          Device.bind "refresh change", @proxy(@render)
          @render()
          $('.savedevice').click (s) =>
            s = Scenario.find($('#scenario_id').val())
            d = Device.find($('#device-template').val())
            s.addDeviceFromTemplate d
            $("##{s.id} ul").append(d.liView()).page()
            @deviceclick()
            true
        deviceclick: ->
          $('.devices').unbind 'click.view'
          $('.devices').bind 'click.view', (s) ->
            sid = @attributes['mid'].value
            device = Device.find sid
            $("##{sid}").remove()
            $("body").append(device.showView())
            $("##{sid}").page()
            $('.updatedevice').click (s) ->
              sid = @attributes['mid'].value
              device = Device.find sid
              for attr in Device.attributes
                v = $("##{sid}-#{attr}").val()
                device.updateAttribute(attr, v) if v?
              device.scenario().updateAttribute(updated_at: new Date())
            $('.deletedevice').click (s) ->
              sid = @attributes['mid'].value
              device = Device.find sid
              if confirm "Remove device '#{device.name}'?"
                $("[mid = \"#{device.id}\"]").remove()
                device.destroy()
                return true
              else
                return false
            true
        render: ->

      exports.Scenarios = Spine.Controller.create
        init: ->
          Scenario.bind "refresh change", @proxy(@render)
          @render()
          $('.savescenario').click (s) ->
            Scenario.create name: $('#scenario_name').val()
            true
        render: ->
          $('#scenarios').html Scenario.indexView()
          # $('#scenarios').page()
          $("#device-template").html Device.selectView()
          $('.scenarios').click (s) ->
            sid = @attributes['mid'].value
            scenario = Scenario.find sid
            $("##{sid}").remove()
            $("body").append(scenario.showView()) #.page()
            App.devices.deviceclick()
            $('#scenario_id').val sid
            exports.gph = new Dygraph document.getElementById(scenario.id + '-graphdiv'), scenario.graphdata(), width: 550, height: 550, drawPoints: true, fillGraph: true, pointSize: 2, drawCallback: (g,is_initial) =>
              g.setAnnotations(scenario.annotations()) if is_initial
            $('.deletescenario').click (s) ->
              sid = @attributes['mid'].value
              scenario = Scenario.find sid
              if confirm "Delete scenario '#{scenario.name}'?"
                scenario.cdestroy()
                return true
              else
                return false
            true

      exports.NrgApp = Spine.Controller.create
        el:
          $ "body"

        elements:
          "#scenarios": "scenariosEl",
          "#devices": "devicesEl"

        init: ->
          Device.fetch()
          Scenario.fetch()

          # testing... clear out everything todo:remove
          # Device.deleteAll()
          # Scenario.deleteAll()

          # data initialization below

          # clear out all the templates
          Device.each (d) -> d.destroy() if d.scenario_id is undefined

          # create our standard templates
          device0 = Device.create name: "Customizable Device", count: 1, rechargable: 1, operating_from: 15, operating_until: 20, units: "Watt", units_provided: 45, units_draw: 20, capacity_unit_hours: 60, in_bus: 1, out_bus: 1
          device1 = Device.create name: "12v LED Light", count: 1, operating_from: 21, operating_until: 1, units: "Watt", units_draw: 1.3, in_bus: 1
          device2 = Device.create name: "12v Incandescent Light", count: 1, operating_from: 21, operating_until: 1, units: "Watt", units_draw: 13, suggestion_device_id: device1.id, in_bus: 1
          device3 = Device.create name: "60Ah Deep-cycle Battery", count: 1, rechargable: 1, units: "Watt", units_draw_charging: 90, capacity_unit_hours: 720, starting_fullness: 100, in_bus: 1, out_bus: 1 # 10.5 - 12.7, 20hour rate c/8 = 90w max
          device3a = Device.create name: "16000 mAh Mobile Battery", count: 1, rechargable: 1, units: "Watt", units_draw: 5, capacity_unit_hours: 80, starting_fullness: 100, in_bus: 1, out_bus: 2
          device4 = Device.create name: "HP Touchpad", count: 1, rechargable: 1, units: "Watt", units_draw: 3, units_draw_charging: 10, capacity_unit_hours: 60, in_bus: 1
          device4a = Device.create name: "HP Palm Pre 3", count: 1, rechargable: 1, units: "Watt", units_draw: 0.1, units_draw_charging: 1, capacity_unit_hours: 5, in_bus: 1
          device4b = Device.create name: "10w Tablet", count: 1, rechargable: 1, units: "Watt", units_draw: 3, units_draw_charging: 10, capacity_unit_hours: 60, in_bus: 1
          device5 = Device.create name: "Macbook Air", count: 1, rechargable: 1, operating_from: 15, operating_until: 2, units: "Watt", units_draw: 5, suggestion_device_id: device4.id, capacity_unit_hours: 30, in_bus: 1
          device6 = Device.create name: "Powerbook", count: 1, rechargable: 1, operating_from: 15, operating_until: 20, units: "Watt", units_draw: 20, suggestion_device_id: device5.id, capacity_unit_hours: 60, in_bus: 1
          device7 = Device.create name: "10w Solar Panel", count: 1, operating_from: 10, operating_until: 17, units: "Watt", units_provided: 10, out_bus: 1
          device8 = Device.create name: "1000w Generator", operating_from: 10, operating_until: 20, units: "Watt", units_provided: 1000, min_burn: 1000, max_burn: 1500, capacity_unit_hours: 10000, on_bus_capacity: 0.50, off_bus_capacity: 1.0, out_bus: 1
          device9 = Device.create name: "High-efficiency Electric Fridge", units: "Watt", units_draw: 7, in_bus: 1 # typical 168 whrs/day or 7 watts http://www.homesteadersupply.com/index.php?main_page=product_info&cPath=21&products_id=139
          device10 = Device.create name: "Propane Fridge", suggestion_device_id: device8.id, units: "Watt", units_draw: 0.1, burner_btu: 600, suggestion_device_id: device9.id, in_bus: 1 # 1560 btu == 2.5g/week 40lb == 10g 30lb == 7.5g
          device11= Device.create name: "Propane Heater with Electric Fan", units: "Watt", units_draw: 5, burner_btu: 1000, operating_from: 19, operating_until: 6, in_bus: 1
          device12= Device.create name: "30lb/7.5g Propane Tank", units: "BTU", capacity_unit_hours: 687000, comment: "91,600 BTU per gallon of propane", out_bus: 1

          if Scenario.count() < 1
            scenario1 = Scenario.create name: "Sample scenario"
            scenario1.addDeviceFromTemplate device4
            scenario1.addDeviceFromTemplate device2, 3
            scenario1.addDeviceFromTemplate device3
            scenario1.addDeviceFromTemplate device7
            scenario1.addDeviceFromTemplate device6
            scenario1.addDeviceFromTemplate device11
            scenario1.addDeviceFromTemplate device12, 2

          @scenarios = Scenarios.init el: @scenariosEl
          @devices = Devices.init el: @devicesEl

      $ ->
        exports.App = NrgApp.init()

  body ->
    div "data-role": "page", id: "menu1", ->
      div "data-role": "header", ->
        h1 "NRG Scenarios"
        a href: "#newscenario", class: "ui-btn-right", "+"
      div "data-role": "content", ->
        div class: "content-secondary", ->
          ul "id": "scenarios", "data-role": "listview"
        div class: "content-primary", ->
          h2 "NRG Energy calculator"
          h4 "Estimate and predict energy usage and reserves using a handy graphing calculator"
          ul ->
            li "Provides settings for common energy sources: battery, propane, generators"
            li "Gives you settings for common users of energy: tablet, fridge, laptop, lights"
            li "Allows you to customize the common devices above"
            li "Allows you to create new devices with custom combinations of attributes"
            li "Allows you to tweak the energy requirements of mobile devices to match your own usage"
          h4 "Use it to..."
          ul ->
            li "Plan the use of mobile devices like a tablet combined with extended batteries"
            li "Estimate your RV energy use"
            li "Plan for upgrades to become more energy efficient and independent"
            li "Remove the guesswork from how much fuel you might need"
          h4 "Get started now"
          ul ->
            li "Try out the sample scenario"
            li "Create a new scenario (+ button above) and add your own custom device list"
            li "More than one of something? Add a device multiple times or change its count attribute"
            li "Switch between scenarios and compare the results"
          p "Brad Midgley bmidgley@gmail.com"

    div "data-role": "page", id: "newscenario", ->
      div "data-role": "header", ->
        a href: '#menu1', "data-icon": "delete", "data-rel": "back", "data-iconpos": "notext"
        h1 "New scenario"
        a href: "#menu1", class: "savescenario", "data-rel": "back", "Save"
      div "data-role": "content", ->
        div "data-role": "fieldcontain", ->
          label for: "name", "Scenario name:"
          input type: "text", name: "scenario_name", id: "scenario_name", value: "New scenario"

    div "data-role": "page", id: "newdevice", ->
      div "data-role": "header", ->
        a href: '#scenario', "data-icon": "delete", "data-rel": "back", "data-iconpos": "notext"
        h1 "New device"
        a href: "#scenario", class: "savedevice", "data-rel": "back", "Save"
      div "data-role": "content", ->
        div "data-role": "fieldcontain", ->
          label for: "Type", class: "select", "Device type:"
          select name: "device-template", id: "device-template"
          input type: "hidden", id: "scenario_id"
