// ProtonMaps code here:
let protocol = new pmtiles.Protocol();
maptilersdk.addProtocol('pmtiles',protocol.tile);

// let PMTILES_URL = 'https://storage.googleapis.com/sandbox-248512.appspot.com/waterways2.pmtiles';
// let PMTILES_URL = 'https://storage.yandexcloud.net/osm-water-validator/waterways.pmtiles';
let PMTILES_URL = 'http://storage.yandexcloud.net/osm-water-validator/waterways_temp.pmtiles';

const p = new pmtiles.PMTiles(PMTILES_URL);
// this is so we share one instance across the JS code and the map renderer
protocol.add(p);

var mCenter = localStorage.theCenter ?? '37.61,55.75'


// MapTiler code from here:
const apiKey = 'z9jR5pdnvvxTxnCPJt9c'
const urlParams = new URLSearchParams(window.location.search); const key = urlParams.get('key') || apiKey;
const fallback_key = urlParams.get('fallback_key') || urlParams.get('key');
const baseMaps = {
  'DATAVIZ': {
    img: 'https://cloud.maptiler.com/static/img/maps/dataviz.png'
  },
  'OPENSTREETMAP': {
    img: 'https://cloud.maptiler.com/static/img/maps/openstreetmap.png'
  },
  'SATELLITE': {
    img: 'https://cloud.maptiler.com/static/img/maps/satellite.png'
  }
}
const initialStyle = maptilersdk.MapStyle[Object.keys(baseMaps)[0]];
maptilersdk.config.apiKey = apiKey;
var map = new maptilersdk.Map({
  container: 'map', // container's id or the HTML element to render the map
  style: initialStyle,
  zoom: localStorage.theZoom ?? 3,
  center: mCenter.split(',').map(parseFloat)
//   center: [37.61, 55.75], // starting position [lng, lat]
//   zoom: 10, // starting zoom
});


map.loadImage('.\\assets\\arrow.png', (error, image) => {
  if (error) throw error;
  // Add the loaded image to the style's sprite with the ID 'kitten'.
  map.addImage('arrow', image);
});

map.on('load', function () {
  // Add Water Errors source.
  map.addSource('water', {
      'type': 'vector',
      'url': 'pmtiles://' + PMTILES_URL,
  });
  // Water polygons layer
  map.addLayer(
      {
          'id': 'water_polygons',
          'type': 'fill',
          'source': 'water',
          'source-layer': 'water_areas',
          'paint': {
            'fill-color': [
              'case',
              ['has', 'errs'], '#fdbf6f',
              '#b8b9e9'
            ]
          }
      },
      // 'River labels' // Add before layers (maybe  label layrs...)
  );
  // Clicable lines
  map.addLayer(
    {
        'id': 'clicable_lines',
        'type': 'line',
        'source': 'water',
        'source-layer': 'water_lines',
        'filter': ['any',
          ['has', 'errs'],
          ['==', 'type', 'l']
        ],
        'paint': {
            'line-opacity': 0.01,
            'line-color': 'white',
            'line-width': 10
        }
    },
    // 'River labels' // Add before layers (maybe  label layrs...)
  );
  // Water lines layer
  map.addLayer(
    {
        'id': 'water_lines',
        'type': 'line',
        'source': 'water',
        'source-layer': 'water_lines',
        'filter': ['any', 
          ['==', 'type', 'r'], 
          ['==', 'type', 'c'], 
          ['==', 'type', 's'], 
          ['==', 'type', 'd']
        ],
        'paint': {
            'line-opacity': 0.8,
            'line-color': [
              'case',
              ['in', '3', ['get', 'errs']], 'red',
              ['has', 'errs'], 'orange',
              '#5b5fd1'
            ],
            'line-width': {
              'stops': [
                [8, 0.5],
                [12, 1.5],
                [20, 3]
              ]
            }
        }
    },
    // 'River labels' // Add before layers (maybe  label layrs...)
  );

  map.addLayer({
    'id': 'triangles',
    'type': 'symbol',
    'source': 'water',
    'source-layer': 'water_lines',
    'minzoom': 12,
    'layout': {
      'symbol-placement': 'line',
      'icon-image': 'arrow',
      'icon-size': 0.6,
      'icon-rotation-alignment': 'map',
      'icon-offset': [0, -1],
    }
  });  

  // Water possible connectors layer
  map.addLayer(
    {
        'id': 'water_connector_lines',
        'type': 'line',
        'source': 'water',
        'source-layer': 'water_lines',
        'filter': ['==', 'type', 'l'], 
        'paint': {
            'line-opacity': 0.8,
            'line-color': '#f701ff',
            'line-dasharray': [1, 0.5],
            'line-width': {
              'stops': [
                [8, 0.5],
                [12, 1.5],
                [20, 3]
              ]
            }
        }
    },
    // 'River labels' // Add before layers (maybe  label layrs...)
  );
  // Water lines layer (tunnels)
  map.addLayer(
    {
        'id': 'tunnels_and_culverts',
        'type': 'line',
        'source': 'water',
        'source-layer': 'water_lines',
        'filter': ['any', 
          ['==', 'type', 'rt'], 
          ['==', 'type', 'ct'], 
          ['==', 'type', 'st'], 
          ['==', 'type', 'dt'], 
        ],
        'paint': {
            'line-opacity': 0.8,
            'line-color': [
              'case',
              ['in', '3', ['get', 'errs']], 'red',
              ['has', 'errs'], 'orange',
              '#5b5fd1'
            ],
            'line-dasharray': [2, 0.5],
            'line-width': {
              'stops': [
                [8, 0.5],
                [12, 1.5],
                [20, 3]
              ]
            }
        }
    },
    // 'River labels' // Add before layers (maybe  label layrs...)
);
// Water Err points layer
  map.addLayer(
      {
          'id': 'water_points',
          'type': 'circle',
          'source': 'water',
          'source-layer': 'err_points',
          'paint': {
              'circle-opacity': 0.6,
              'circle-color': '#ffa500',
              'circle-radius': 4
          }
      },
      // 'River labels' // Add before layers (maybe  label layrs...)
  );
  // Water line labels
  map.addLayer(
    {
        'id': 'water_line_labels',
        'type': 'symbol',
        'source': 'water',
        'source-layer': 'water_lines',
        // 'filter': ['in', 'waterway', ['get', 'tags']],
        'layout': {
        'text-font': [
            'Roboto Italic',
            'Noto Sans Italic'
          ],
          'text-size': {
            'stops': [
                [12, 12],
                [16, 14],
                [22, 20]
            ]
          },
          'text-field': [
            'get',
            'name'
        ],
        'visibility': 'visible',
        'symbol-placement': 'line'
        },
        'paint': {
            'text-color': [
              'case',
              ['in', '3', ['get', 'errs']], 'red',
              ['has', 'errs'], 'orange',
              ['!', ['has', 'id']], '#f701ff',
              '#5b5fd1'
            ],
            'text-halo-blur': 1,
            'text-halo-color': 'white',
            'text-halo-width': {
              'stops': [
                [10, 1],
                [18, 2]
              ]
            }
        }
    },
    // 'River labels' // Add before layers (maybe  label layrs...)
  );
  // Water area labels
  map.addLayer(
    {
        'id': 'water_area_labels',
        'type': 'symbol',
        'source': 'water',
        'source-layer': 'water_areas',
        'layout': {
        'text-font': [
            'Roboto Italic',
            'Noto Sans Italic'
          ],
          'text-size': {
            'stops': [
              [12, 12],
              [16, 14],
              [22, 20]
            ]
          },
          'text-field': [
            'get',
            'name'
        ],
        'visibility': 'visible',
        'symbol-placement': 'point'
        },
        'paint': {
            'text-color': [
              'case',
              ['has', 'errs'], 'orange',
              '#5b5fd1'
            ],
            'text-halo-blur': 1,
            'text-halo-color': 'white',
            'text-halo-width': {
              'stops': [
                [10, 1],
                [18, 2]
              ]
            }
        }
    },
    // 'River labels' // Add before layers (maybe  label layrs...)
  );
  
});

// map.showTileBoundaries = true;

// Popup logic here
// When a click event occurs on a feature in the water_lines layer, open a popup at the
// location of the feature, with description HTML from its properties.
map.on('click', 'clicable_lines', function (e) {
  new maptilersdk.Popup()
                .setLngLat(e.lngLat)
                .setHTML(e.features[0].properties.errs)
                .addTo(map);
});

// Change the cursor to a pointer when the mouse is over the water_lines layer.
map.on('mouseenter', 'clicable_lines', function () {
  map.getCanvas().style.cursor = 'pointer';
});

// Change it back to a pointer when it leaves.
map.on('mouseleave', 'clicable_lines', function () {
  map.getCanvas().style.cursor = '';
});

// Popup logic ends here

map.on('load', function() {
  const targets = {
    water_points:   'Error Points',
    water_lines:    'Water Lines',
    water_polygons: 'Water Areas',
  };
  const options = {
    showDefault: false,
    showCheckbox: true,
    onlyRendered: true,
    reverseOrder: true,
    title: 'Перечень доступных слоёв'
  };
  map.addControl(new MaplibreLegendControl.MaplibreLegendControl(targets, options), 'top-left');
});

// map.on('mousemove', function (e) {
//     var features = map.queryRenderedFeatures(e.point);

//     // Limit the number of properties we're displaying for
//     // legibility and performance
//     var displayProperties = [
//         'type',
//         'properties',
//         'id',
//         'layer',
//         'source',
//         'sourceLayer',
//         'state'
//     ];

//     var displayFeatures = features.map(function (feat) {
//         var displayFeat = {};
//         displayProperties.forEach(function (prop) {
//             displayFeat[prop] = feat[prop];
//         });
//         return displayFeat;
//     });

//     document.getElementById('features').innerHTML = JSON.stringify(
//         displayFeatures,
//         null,
//         2
//     );
// });

// Store Map zoom and center into LocalStorage
map.on('zoomend', function(e) {
    localStorage.theZoom = map.getZoom();
    localStorage.theCenter = map.getCenter().toArray()
});

map.on('moveend', function(f) {
    localStorage.theZoom   = map.getZoom();
    localStorage.theCenter = map.getCenter().toArray()
});

// Disable map rotation
map.dragRotate.disable();

// disable map rotation using touch rotation gesture
map.touchZoomRotate.disableRotation();

// map.showTileBoundaries = true;


class layerSwitcherControl {

  constructor(options) {
    this._options = {...options};
    this._container = document.createElement('div');
    this._container.classList.add('maplibregl-ctrl');
    this._container.classList.add('maplibregl-ctrl-basemaps');
    this._container.classList.add('closed');
    switch (this._options.expandDirection || 'right') {
      case 'top':
        this._container.classList.add('reverse');
      case 'down':
        this._container.classList.add('column');
        break;
      case 'left':
        this._container.classList.add('reverse');
      case 'right':
        this._container.classList.add('row');
    }
    this._container.addEventListener('mouseenter', () => {
      this._container.classList.remove('closed');
    });
    this._container.addEventListener('mouseleave', () => {
      this._container.classList.add('closed');
    });
  }

  onAdd(map) {
    this._map = map;
    const basemaps = this._options.basemaps;
    Object.keys(basemaps).forEach((layerId) => {
      const base = basemaps[layerId];
      const basemapContainer = document.createElement('img');
      basemapContainer.src = base.img;
      basemapContainer.classList.add('basemap');
      basemapContainer.dataset.id = layerId;
      basemapContainer.addEventListener('click', () => {
        const activeElement = this._container.querySelector('.active');
        activeElement.classList.remove('active');
        basemapContainer.classList.add('active');
        map.setStyle(maptilersdk.MapStyle[layerId]);
      });
      basemapContainer.classList.add('hidden');
      this._container.appendChild(basemapContainer);
      if (this._options.initialBasemap.id === layerId) {
          basemapContainer.classList.add('active');
      }
    });
    return this._container;
  }

  onRemove(){
    this._container.parentNode?.removeChild(this._container);
    delete this._map;
  }
}

map.addControl(new layerSwitcherControl({basemaps: baseMaps, initialBasemap: initialStyle}), 'bottom-left');
